import Foundation
import Network

/// Mac 侧 HTTP 代理入口：把 Linux 侧 `http_proxy/https_proxy` 指向的端口经 SSH
/// 反向转发到本监听器，由 App 自己实现 HTTP 代理语义——远端不再依赖 Privoxy。
///
/// 三种上游模式（按本地代理实测协议与连接模式选择）：
/// - `.pipe`：上游是 HTTP/Mixed 代理 → 纯透明字节管道。客户端的 CONNECT 与
///   绝对格式请求本就是标准 HTTP 代理协议，透传即可（零解析，语义最全）。
/// - `.socks5`：上游是 SOCKS5 代理 → 解析 CONNECT 请求行，向上游完成 SOCKS5
///   握手后按 200 应答并透传（仅支持 CONNECT，即 https_proxy 用法）。
/// - `.direct`：动态 SOCKS5 回退场景没有本地代理 → 解析 CONNECT 后由 Mac
///   网络栈直连目标（与动态模式的出站语义一致）。
///
/// 隐私与边界：只监听 127.0.0.1；流量统计由静态转发主 Relay 承担，本入口不计
/// 业务字节（面板语义不变，文档如实说明）；SOCKS5 上游无认证（回环代理惯例，
/// 与静态转发探测的假设一致）。
protocol HTTPEntryRelaying: AnyObject, Sendable {
    /// 监听器启动成功后死亡（端口被抢/系统回收）的上报通道：启动期失败经
    /// start() 抛错感知，不走此回调（语义与 TCPRelaying.onFailure 一致）。
    var onFailure: (@Sendable (String) -> Void)? { get set }
    func start(port: UInt16, mode: HTTPEntryMode) async throws -> UInt16
    /// 上游端点变化时切换模式/目标：只影响之后接受的连接（语义与主 Relay 一致）。
    func retarget(to mode: HTTPEntryMode)
    func stop()
}

enum HTTPEntryMode: Sendable {
    case pipe(LocalProxyEndpoint)
    case socks5(LocalProxyEndpoint)
    case direct
}

struct HTTPEntryRelayFactory: Sendable {
    private let makeImpl: @Sendable () -> any HTTPEntryRelaying
    /// 生产用默认构造；测试可注入替身（如始终启动失败的入口）。
    init(make: (@Sendable () -> any HTTPEntryRelaying)? = nil) {
        makeImpl = make ?? { HTTPEntryRelay() }
    }
    func make() -> any HTTPEntryRelaying { makeImpl() }
}

final class HTTPEntryRelay: HTTPEntryRelaying, @unchecked Sendable {
    var onFailure: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "ProxyBridge.http-entry-relay", qos: .utility)
    private var listener: NWListener?
    private var connections: [UUID: EntryConnection] = [:]
    private var startup: CheckedContinuation<UInt16, Error>?
    private var startupTimeout: DispatchWorkItem?
    private var stopped = false
    private var started = false
    private var mode: HTTPEntryMode?
    private let connectionLimit = 256

    func start(port: UInt16, mode: HTTPEntryMode) async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    // 二次启动防护（与 TCPRelay 一致）：重复 start 会创建第二个
                    // NWListener 并覆盖 startup，前一个 continuation 永不恢复
                    guard !stopped, !started else { continuation.resume(throwing: CancellationError()); return }
                    switch mode {
                    case .pipe(let endpoint), .socks5(let endpoint):
                        guard LocalProxyEndpointRule.isValid(host: endpoint.host, port: endpoint.port) else {
                            continuation.resume(throwing: NSError(
                                domain: "ProxyBridge.HTTPEntry", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "HTTP 入口上游必须是合法回环代理"]
                            ))
                            return
                        }
                    case .direct:
                        break
                    }
                    started = true
                    self.mode = mode
                    startup = continuation
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
                        let timeout = DispatchWorkItem { [weak self] in self?.fail("HTTP 入口启动超时") }
                        startupTimeout = timeout
                        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
                        listener.start(queue: queue)
                    } catch {
                        fail(error.localizedDescription)
                    }
                }
            }
        } onCancel: { self.stop() }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            startupTimeout?.cancel(); startupTimeout = nil
            startup?.resume(throwing: CancellationError()); startup = nil
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel(); listener = nil
            connections.values.forEach { $0.close() }
            connections.removeAll()
        }
    }

    /// 切换上游模式/目标：只影响之后接受的连接；已建立连接按旧模式自然结束。
    func retarget(to mode: HTTPEntryMode) {
        queue.async { [self] in
            guard !stopped else { return }
            self.mode = mode
            for connection in connections.values where !connection.isTunneling {
                connection.close()
            }
        }
    }

    private func listenerState(_ state: NWListener.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else {
                fail("无法读取 HTTP 入口监听端口"); return
            }
            startupTimeout?.cancel(); startupTimeout = nil
            startup?.resume(returning: port); startup = nil
        case .failed(let error):
            fail("HTTP 入口监听失败：\(error.localizedDescription)")
        case .waiting(let error):
            // .waiting 非终态（等待网络条件改善后可自行恢复）；但端口被占用
            // 这类确定性失败必须立即报错，否则拖到 5 秒启动超时才失败
            if case .posix(.EADDRINUSE) = error {
                fail("HTTP 入口监听失败：\(error.localizedDescription)")
            }
        default:
            break
        }
    }

    private func fail(_ detail: String) {
        // 启动期失败经 continuation 抛错（调用方在 start() 处感知）；启动成功后
        // 监听器死亡没有抛错通道，必须经 onFailure 立即上报，否则本地端口消失
        // 最长要等一个健康检查周期才被发现（对齐 TCPRelay）。stop() 先摘除
        // stateUpdateHandler 再 cancel 且全程未调用 fail()，主动停止不会误触。
        let starting = startup != nil
        startup?.resume(throwing: NSError(
            domain: "ProxyBridge.HTTPEntry", code: 2,
            userInfo: [NSLocalizedDescriptionKey: detail]
        ))
        startup = nil
        stop()
        if !starting { onFailure?(detail) }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, let mode, connections.count < connectionLimit else {
            connection.cancel(); return
        }
        let entry = EntryConnection(connection: connection, mode: mode, queue: queue)
        connections[entry.id] = entry
        entry.finished = { [weak self] id in self?.connections[id] = nil }
        entry.start()
    }
}

/// 单条入口连接（状态机，全部回调在 relay queue 上串行执行）：
/// pipe：upstream TCP ready 即双向透传（零解析）；
/// socks5：解析 CONNECT → 上游 SOCKS5 握手（NO-AUTH）→ 200 → 透传；
/// direct：解析 CONNECT → 直连 authority → 200 → 透传。
private final class EntryConnection: @unchecked Sendable {
    let id = UUID()
    var finished: ((UUID) -> Void)?

    private let incoming: NWConnection
    private let mode: HTTPEntryMode
    private let queue: DispatchQueue

    private enum Phase {
        case awaitingHeader
        case connecting
        case tunneling
        /// 拒绝响应发送中；close() 在发送完成或超时后执行实际清理。
        case rejecting
        case closed
    }

    private var phase: Phase = .awaitingHeader
    /// 供 retarget 区分在途连接（语义与主 Relay 的 isEstablished 一致）。
    var isTunneling: Bool { phase == .tunneling }
    private var isClosing: Bool { phase == .rejecting || phase == .closed }
    private var incomingReady = false
    private var upstreamReady = false
    private var tunnelEstablished = false
    /// 双向泵是否已启动（幂等）：completeTunnel 会被 send completion 与
    /// establishTunnel 多次触发，重复启动会打破「每方向至多一个在途 receive」
    /// 的背压设计（与 TCPRelay 同一约定）。
    private var pumpingStarted = false
    /// 半关闭语义（与 TCPRelay.Pair 一致）：单方向 EOF 只关该方向，
    /// 两个方向各自观察到 EOF 才整体关闭，对向仍在传输的响应不被掐断。
    private var incomingEnded = false
    private var outgoingEnded = false
    private var outgoing: NWConnection?
    /// CONNECT 解析出的目标（socks5/direct 模式）。
    private var authority: (host: String, port: UInt16)?
    private var headerBuffer = Data()
    /// 头部之后的余量字节（明文请求的 body 等），随翻译后的头部一起转发。
    private var remainderAfterHead = Data()
    /// 明文请求：翻译后的请求行 + 头（CONNECT 请求为 nil）。
    private var plainRequestHead: String?
    private var isConnect = false
    private var handshakeStarted = false
    private var deadline: DispatchWorkItem?
    private let headerLimit = 16 * 1024

    init(connection: NWConnection, mode: HTTPEntryMode, queue: DispatchQueue) {
        self.incoming = connection
        self.mode = mode
        self.queue = queue
    }

    func start() {
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        deadline = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        incoming.stateUpdateHandler = { [weak self] state in
            guard let self, !self.isClosing else { return }
            switch state {
            case .ready:
                self.incomingReady = true
                self.startReadingIfNeeded()
                self.maybeStartTunnel()
            case .failed, .cancelled:
                self.close()
            case .waiting:
                break // 非终态：等待路径恢复，10 秒建立期限兜底
            default:
                break
            }
        }
        incoming.start(queue: queue)
        switch mode {
        case .pipe(let endpoint):
            openUpstream(toHost: endpoint.host, port: UInt16(endpoint.port))
        case .socks5(let endpoint):
            // 上游连接先行；CONNECT 解析完成后在 upstreamReady 时立即握手
            openUpstream(toHost: endpoint.host, port: UInt16(endpoint.port))
        case .direct:
            break // 等 CONNECT 解析出 authority 再连接
        }
    }

    private func startReadingIfNeeded() {
        guard phase == .awaitingHeader else { return }
        switch mode {
        case .pipe:
            phase = .connecting // 零解析：字节从 ready 起双向透传
        case .socks5, .direct:
            readHeaderChunk()
        }
    }

    // MARK: - 上游连接

    private func openUpstream(toHost host: String, port: UInt16) {
        guard let targetPort = NWEndpoint.Port(rawValue: port) else { reject("400 Bad Request"); return }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: targetPort, using: parameters)
        outgoing = upstream
        upstream.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            guard let self, !self.isClosing else { return }
            switch state {
            case .ready:
                self.upstreamReady = true
                switch self.mode {
                case .pipe:
                    self.establishTunnel()
                case .socks5:
                    self.startHandshakeIfPossible()
                case .direct:
                    self.completeTunnel()
                }
            case .failed, .cancelled:
                self.reject("502 Bad Gateway")
            case .waiting(let error):
                // 与主 Relay 同语义：ECONNREFUSED 经 .waiting 上报且不会自行转 failed，
                // 必须立即拒绝；其余 .waiting（接口/路径等待）非终态，交给期限兜底
                if case .posix(.ECONNREFUSED) = error { self.reject("502 Bad Gateway") }
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    // MARK: - CONNECT 头解析（socks5 / direct）

    private func readHeaderChunk() {
        incoming.receive(minimumIncompleteLength: 1, maximumLength: headerLimit) { [weak self] data, _, eof, error in
            guard let self, self.phase == .awaitingHeader else { return }
            guard error == nil else { self.close(); return }
            if let data { self.headerBuffer.append(data) }
            if self.headerBuffer.count > self.headerLimit {
                self.reject("400 Bad Request"); return
            }
            if let range = self.headerBuffer.range(of: Data("\r\n\r\n".utf8)) {
                self.phase = .connecting
                let head = String(decoding: self.headerBuffer[..<range.lowerBound], as: UTF8.self)
                self.remainderAfterHead = Data(self.headerBuffer[range.upperBound...])
                self.headerBuffer.removeAll()
                self.handleRequestHead(head)
                return
            }
            if eof {
                self.reject("400 Bad Request"); return
            }
            self.readHeaderChunk()
        }
    }

    private func handleRequestHead(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ").map(String.init)
        guard parts.count >= 3 else {
            reject("400 Bad Request"); return
        }
        if parts[0].uppercased() == "CONNECT" {
            // CONNECT（https_proxy 用法）：解析 authority（含 [IPv6]:port 形式），
            // 握手后回 200 并透传
            guard let parsed = Self.parseAuthority(parts[1]) else {
                reject("400 Bad Request"); return
            }
            authority = parsed
            isConnect = true
        } else {
            // 绝对格式明文请求（http_proxy 用法，如健康检查 GET）：翻译为源站请求——
            // 请求行改写为源站形式，其余头与头部之后的余量字节原样跟随
            guard let url = URL(string: parts[1]), let host = url.host, !host.isEmpty else {
                reject("400 Bad Request"); return
            }
            let defaultPort = url.scheme?.lowercased() == "https" ? 443 : 80
            let port = UInt16(url.port ?? defaultPort)
            // 空 path 带查询（GET http://host?x=1）的源站形式是 "/?x=1"，查询串不能丢
            let path = url.path.isEmpty ? "/" : url.path
            let originTarget = path + (url.query.map { "?\($0)" } ?? "")
            let headerTail = lines.dropFirst().joined(separator: "\r\n")
            plainRequestHead = "\(parts[0]) \(originTarget) \(parts[2])\r\n\(headerTail)\r\n\r\n"
            authority = (host, port)
            isConnect = false
        }
        switch mode {
        case .direct:
            openUpstream(toHost: authority!.host, port: authority!.port)
        case .socks5:
            startHandshakeIfPossible()
        case .pipe:
            reject("500 Internal Server Error") // pipe 模式不经过解析路径
        }
    }

    /// 解析 CONNECT 的 authority：`host:port` 或 `[IPv6]:port`（如 `[::1]:443`）。
    private static func parseAuthority(_ target: String) -> (host: String, port: UInt16)? {
        if target.hasPrefix("[") {
            guard let close = target.firstIndex(of: "]") else { return nil }
            let host = String(target[target.index(after: target.startIndex)..<close])
            let rest = target[target.index(after: close)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), !host.isEmpty else { return nil }
            return (host, port)
        }
        let hostPort = target.split(separator: ":").map(String.init)
        guard hostPort.count == 2, let port = UInt16(hostPort[1]), !hostPort[0].isEmpty else { return nil }
        return (hostPort[0], port)
    }

    // MARK: - SOCKS5 握手（无认证，回环上游）

    private func startHandshakeIfPossible() {
        guard case .socks5 = mode, let authority,
              upstreamReady, incomingReady, !handshakeStarted, let upstream = outgoing else { return }
        handshakeStarted = true
        let greeting = Data([0x05, 0x01, 0x00]) // VER=5, 1 个方法，NO-AUTH
        upstream.send(content: greeting, completion: .contentProcessed { [weak self] error in
            guard let self, !self.isClosing else { return }
            guard error == nil else { self.reject("502 Bad Gateway"); return }
            self.receiveExactly(on: upstream, count: 2) { reply in
                guard reply.count == 2, reply[0] == 0x05, reply[1] == 0x00 else {
                    self.reject("502 Bad Gateway"); return
                }
                self.sendConnectRequest(on: upstream, host: authority.host, port: authority.port)
            }
        })
    }

    private func sendConnectRequest(on upstream: NWConnection, host: String, port: UInt16) {
        var request = Data([0x05, 0x01, 0x00, 0x03]) // CONNECT，地址类型=域名（IP 亦可用域名形式）
        let utf8 = Data(host.utf8)
        request.append(UInt8(utf8.count))
        request.append(utf8)
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xff))
        upstream.send(content: request, completion: .contentProcessed { [weak self] error in
            guard let self, !self.isClosing else { return }
            guard error == nil else { self.reject("502 Bad Gateway"); return }
            self.receiveSOCKS5Reply(on: upstream)
        })
    }

    private func receiveSOCKS5Reply(on upstream: NWConnection) {
        // VER REP RSV ATYP + ADDR（可变长）+ PORT
        receiveExactly(on: upstream, count: 4) { [weak self] head in
            guard let self, head.count == 4, head[0] == 0x05, head[1] == 0x00 else {
                self?.reject("502 Bad Gateway"); return
            }
            switch head[3] {
            case 0x01, 0x04:
                let addrLen = head[3] == 0x01 ? 4 : 16
                self.receiveExactly(on: upstream, count: addrLen + 2) { [weak self] _ in
                    self?.completeTunnel()
                }
            case 0x03:
                self.receiveExactly(on: upstream, count: 1) { [weak self] lengthByte in
                    guard let self, let length = lengthByte.first.map({ Int($0) }) else {
                        self?.reject("502 Bad Gateway"); return
                    }
                    self.receiveExactly(on: upstream, count: length + 2) { [weak self] _ in
                        self?.completeTunnel()
                    }
                }
            default:
                self.reject("502 Bad Gateway")
            }
        }
    }

    // MARK: - 隧道建立与透传

    /// 隧道建立（pipe：两端 TCP ready 即成；socks5/direct：握手/连接完成并应答后）。
    private func establishTunnel() {
        guard !isClosing, !tunnelEstablished, outgoing != nil else { return }
        tunnelEstablished = true
        phase = .tunneling
        deadline?.cancel(); deadline = nil
        maybeStartTunnel()
    }

    /// SOCKS5/直连路径上游就绪：CONNECT 向客户端回 200；明文请求把翻译后的
    /// 头部与余量字节发给上游，然后双向透传。
    private func completeTunnel() {
        guard !isClosing, !tunnelEstablished, let upstream = outgoing else { return }
        if isConnect {
            // 先回 200，再把头部之后已读出的余量字节补发给上游——部分客户端
            // 不等 200 应答就随 CONNECT 管线化发送（如 TLS ClientHello），这些
            // 字节已从 socket 读出、缓存在 remainderAfterHead，不补发即永久丢失。
            // 全部完成后再建立隧道启动泵，保证发往上游的字节序与客户端写入一致
            incoming.send(content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), completion: .contentProcessed { [weak self] error in
                guard let self, !self.isClosing else { return }
                guard error == nil else { self.close(); return }
                let remainder = self.remainderAfterHead
                self.remainderAfterHead = Data()
                guard !remainder.isEmpty else { self.establishTunnel(); return }
                upstream.send(content: remainder, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !self.isClosing else { return }
                    guard sendError == nil else { self.close(); return }
                    self.establishTunnel()
                })
            })
        } else {
            var request = Data((plainRequestHead ?? "").utf8)
            request.append(remainderAfterHead)
            remainderAfterHead = Data()
            plainRequestHead = nil
            upstream.send(content: request, completion: .contentProcessed { [weak self] error in
                guard let self, !self.isClosing else { return }
                guard error == nil else { self.reject("502 Bad Gateway"); return }
                self.maybeStartTunnel()
            })
            establishTunnel()
        }
    }

    private func maybeStartTunnel() {
        guard tunnelEstablished, incomingReady, upstreamReady, !pumpingStarted, let upstream = outgoing else { return }
        pumpingStarted = true
        pump(from: incoming, to: upstream)
        pump(from: upstream, to: incoming)
    }

    private func receiveExactly(on connection: NWConnection, count: Int, then: @escaping (Data) -> Void) {
        guard count > 0 else { then(Data()); return }
        let box = Accumulator()
        receiveChunk(on: connection, remaining: count, box: box, then: then)
    }

    /// 同一串行 queue 上的累积缓冲（避免转义闭包捕获 inout）。
    private final class Accumulator: @unchecked Sendable {
        var data = Data()
    }

    private func receiveChunk(on connection: NWConnection, remaining: Int, box: Accumulator, then: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, eof, error in
            guard let self, !self.isClosing else { return }
            guard error == nil, let data, !eof else { self.reject("502 Bad Gateway"); return }
            box.data.append(data.prefix(remaining))
            let left = remaining - box.data.count
            if left <= 0 { then(box.data) } else { self.receiveChunk(on: connection, remaining: left, box: box, then: then) }
        }
    }

    // MARK: - 应答与关闭

    private func reject(_ status: String) {
        guard !isClosing else { return }
        phase = .rejecting
        deadline?.cancel()
        let response = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        // 兜底：对端不读取响应时不能永久占用名额
        let cleanupTimeout = DispatchWorkItem { [weak self] in self?.close() }
        deadline = cleanupTimeout
        queue.asyncAfter(deadline: .now() + 5, execute: cleanupTimeout)
        incoming.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    func close() {
        guard phase != .closed else { return }
        phase = .closed
        deadline?.cancel(); deadline = nil
        incoming.stateUpdateHandler = nil
        incoming.cancel()
        outgoing?.stateUpdateHandler = nil
        outgoing?.cancel()
        let callback = finished
        finished = nil
        callback?(id)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        let fromIncoming = source === incoming
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, eof, error in
            guard let self, self.phase == .tunneling else { return }
            guard error == nil else { self.close(); return }
            destination.send(content: data, contentContext: eof ? .finalMessage : .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] sendError in
                guard let self, self.phase == .tunneling else { return }
                guard sendError == nil else { self.close(); return }
                if eof {
                    // 单方向 EOF 只结束该方向（半关闭）：明文请求场景下客户端
                    // shutdown(SHUT_WR) 后仍要等完整响应，整体关闭会截断在途数据
                    if fromIncoming { self.incomingEnded = true } else { self.outgoingEnded = true }
                    if self.incomingEnded && self.outgoingEnded { self.close() }
                } else {
                    self.pump(from: source, to: destination)
                }
            })
        }
    }
}
