import Foundation
import Network

protocol TCPRelaying: AnyObject, Sendable {
    var sessionID: UUID { get }
    var onStatistics: (@Sendable (TrafficSnapshot) -> Void)? { get set }
    var onFailure: (@Sendable (String) -> Void)? { get set }
    func start(port: UInt16, target: LocalProxyEndpoint) async throws -> UInt16
    /// 本地代理端点变化时切换转发目标：只影响之后接受的连接；
    /// 已建立的连接不受影响（旧端点死亡时对端会自然断开）。
    func retarget(to target: LocalProxyEndpoint)
    func stop()
}
protocol TCPRelayMaking: Sendable { func make(profileID: UUID) -> any TCPRelaying }
struct TCPRelayFactory: TCPRelayMaking {
    func make(profileID: UUID) -> any TCPRelaying { TCPRelay(profileID: profileID) }
}

/// All socket state and counters live on one utility queue. At most one 64 KB
/// receive/send is outstanding per direction, so slow peers exert backpressure.
final class TCPRelay: TCPRelaying, @unchecked Sendable {
    let sessionID = UUID()
    var onStatistics: (@Sendable (TrafficSnapshot) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "ProxyBridge.tcp-relay", qos: .utility)
    private let profileID: UUID
    private var listener: NWListener?
    private var pairs: [UUID: Pair] = [:]
    private var startup: CheckedContinuation<UInt16, Error>?
    private var startupTimeout: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var started = false
    private var target: LocalProxyEndpoint?
    private var value: TrafficSnapshot
    private var lastUpload: UInt64 = 0
    private var lastDownload: UInt64 = 0
    private var lastTick = DispatchTime.now().uptimeNanoseconds
    private var sampleID: UInt64 = 0
    private let connectionLimit = 256

    init(profileID: UUID) {
        self.profileID = profileID
        value = TrafficSnapshot(profileID: profileID, sessionID: sessionID)
    }

    func start(port: UInt16, target: LocalProxyEndpoint) async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !stopped, !started else { continuation.resume(throwing: CancellationError()); return }
                    guard LocalProxyEndpointRule.isValid(host: target.host, port: target.port) else {
                        continuation.resume(throwing: NSError(domain: "ProxyBridge.Relay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Relay 目标必须是合法回环代理"])); return
                    }
                    started = true; self.target = target; startup = continuation
                    do {
                        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
                        let parameters = NWParameters(tls: nil, tcp: tcp)
                        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
                        parameters.allowLocalEndpointReuse = false
                        parameters.preferNoProxies = true
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] state in self?.listenerState(state) }
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        let timeout = DispatchWorkItem { [weak self] in self?.fail("本地 Relay 启动超时") }
                        startupTimeout = timeout
                        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
                        listener.start(queue: queue)
                    } catch { fail(error.localizedDescription) }
                }
            }
        } onCancel: { self.stop() }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    /// 切换上游目标（本地代理端口漂移/重启场景）。监听端口与 SSH 转发保持不变，
    /// 未建立完成的连接立即关闭（旧目标大概率已死，等 10 秒握手超时只会拖慢恢复）。
    func retarget(to target: LocalProxyEndpoint) {
        queue.async { [self] in
            guard !stopped, started,
                  LocalProxyEndpointRule.isValid(host: target.host, port: target.port) else { return }
            self.target = target
            for pair in pairs.values where !pair.isEstablished { pair.close() }
        }
    }

    private func listenerState(_ state: NWListener.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { fail("无法读取 Relay 监听端口"); return }
            value.relayPort = port; value.isRunning = true
            lastTick = DispatchTime.now().uptimeNanoseconds
            value.sequence += 1
            startupTimeout?.cancel(); startupTimeout = nil
            startup?.resume(returning: port); startup = nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.publishTick() }
            self.timer = timer; timer.resume(); onStatistics?(value)
        case .failed(let error), .waiting(let error): fail("本地 Relay 监听失败：\(error.localizedDescription)")
        default: break
        }
    }

    private func fail(_ detail: String) {
        let starting = startup != nil
        startup?.resume(throwing: NSError(domain: "ProxyBridge.Relay", code: 2, userInfo: [NSLocalizedDescriptionKey: detail])); startup = nil
        stopOnQueue()
        if !starting { onFailure?(detail) }
    }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        startupTimeout?.cancel(); startupTimeout = nil
        startup?.resume(throwing: CancellationError()); startup = nil
        timer?.cancel(); timer = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let connections = Array(pairs.values); pairs.removeAll()
        connections.forEach { $0.close() }
        value.sequence += 1
        value.isRunning = false; value.uploadRate = 0; value.downloadRate = 0
        value.activeConnections = 0
        onStatistics?(value)
    }

    private func accept(_ incoming: NWConnection) {
        guard !stopped, let target, pairs.count < connectionLimit else { incoming.cancel(); return }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        let outgoing = NWConnection(host: NWEndpoint.Host(target.host), port: NWEndpoint.Port(rawValue: UInt16(target.port))!, using: parameters)
        let pair = Pair(incoming: incoming, outgoing: outgoing, queue: queue)
        pairs[pair.id] = pair
        pair.transferred = { [weak self] upload, count in
            guard let self, !self.stopped else { return }
            if upload { self.value.uploadBytes += UInt64(count) }
            else { self.value.downloadBytes += UInt64(count) }
        }
        pair.finished = { [weak self] id in self?.pairs[id] = nil }
        pair.start()
    }

    private func publishTick() {
        guard !stopped else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let duration = Double(now - lastTick) / 1_000_000_000
        guard duration > 0 else { return }
        value.sequence += 1
        value.uploadRate = Double(value.uploadBytes - lastUpload) / duration
        value.downloadRate = Double(value.downloadBytes - lastDownload) / duration
        value.activeConnections = pairs.count
        sampleID += 1
        value.samples.append(TrafficRateSample(id: sampleID, time: Date(), upload: value.uploadRate, download: value.downloadRate))
        value.samples.removeAll { $0.time.timeIntervalSinceNow < -60 }
        if value.samples.count > 60 { value.samples.removeFirst(value.samples.count - 60) }
        lastUpload = value.uploadBytes; lastDownload = value.downloadBytes; lastTick = now
        onStatistics?(value)
    }

    private final class Pair: @unchecked Sendable {
        let id = UUID()
        let incoming: NWConnection
        let outgoing: NWConnection
        let queue: DispatchQueue
        var transferred: ((Bool, Int) -> Void)?
        var finished: ((UUID) -> Void)?
        private var ready = Set<Bool>()
        private var ended = Set<Bool>()
        private var closed = false
        private var began = false
        private var deadline: DispatchWorkItem?
        init(incoming: NWConnection, outgoing: NWConnection, queue: DispatchQueue) {
            self.incoming = incoming; self.outgoing = outgoing; self.queue = queue
        }
        /// 双向均已就绪、开始泵数据（供 Relay 切换目标时区分在途新旧连接）。
        var isEstablished: Bool { began }
        func start() {
            for (connection, upload) in [(incoming, true), (outgoing, false)] {
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.closed else { return }
                    switch state {
                    case .ready:
                        self.ready.insert(upload)
                        if self.ready.count == 2 && !self.began {
                            self.began = true; self.deadline?.cancel(); self.deadline = nil
                            self.pump(upload: true); self.pump(upload: false)
                        }
                    case .failed, .cancelled:
                        // A terminal state may precede delivery of buffered input.
                        // Established pumps drain receive completions before closing.
                        if !self.began { self.close() }
                    case .waiting: self.close()
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
            let timeout = DispatchWorkItem { [weak self] in self?.close() }
            deadline = timeout; queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        }
        func pump(upload: Bool) {
            guard !closed else { return }
            let source = upload ? incoming : outgoing
            let destination = upload ? outgoing : incoming
            source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, eof, error in
                guard let self, !self.closed else { return }
                guard error == nil else { self.close(); return }
                // .finalMessage closes only the sending half. The reverse pump
                // remains active until it independently observes its own EOF.
                destination.send(content: data, contentContext: eof ? .finalMessage : .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !self.closed else { return }
                    guard sendError == nil else { self.close(); return }
                    self.transferred?(upload, data?.count ?? 0)
                    if eof {
                        self.ended.insert(upload)
                        if self.ended.count == 2 { self.close() }
                    } else { self.pump(upload: upload) }
                })
            }
        }
        func close() {
            guard !closed else { return }
            closed = true; deadline?.cancel(); deadline = nil
            incoming.stateUpdateHandler = nil; outgoing.stateUpdateHandler = nil
            incoming.cancel(); outgoing.cancel()
            transferred = nil
            let callback = finished; finished = nil; callback?(id)
        }
    }
}
