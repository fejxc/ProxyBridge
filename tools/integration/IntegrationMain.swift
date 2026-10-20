// 集成测试主程序：真实 ssh 子进程 + 用户态 sshd + 真实 Relay / HTTPEntryRelay /
// 真实远端探测（SSHRemoteProbe），验证端到端数据路径。
// 编译方式见 scripts/integration_test.sh（生产源码 + 本目录）。
// 与冒烟测试的分工：冒烟验证状态机与纯函数；这里验证「进程、端口、隧道、字节」。

import Foundation
import Network

// MARK: - 本地测试服务

/// 源站 HTTP 服务：任何请求都返回 200 + 固定标记（集成测试链路的终点）。
final class WebOrigin: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16 = 0

    init() throws {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            Self.serve(connection)
        }
        listener.start(queue: DispatchQueue(label: "pb-integration-web"))
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    private static func serve(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "pb-integration-web-conn"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
            if error != nil { connection.cancel(); return }
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 25\r\nConnection: close\r\n\r\nPROXYBRIDGE-INTEGRATION-OK\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    func stop() { listener.cancel() }
}

/// 假 SOCKS5 上游：固定 NO-AUTH 握手，CONNECT 一律放行并管道到源站。
final class FakeSocksUpstream: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16 = 0

    init(webPort: UInt16) throws {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            Self.serve(connection, webPort: webPort)
        }
        listener.start(queue: DispatchQueue(label: "pb-integration-socks"))
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    private static func serve(_ connection: NWConnection, webPort: UInt16) {
        connection.start(queue: DispatchQueue(label: "pb-integration-socks-conn"))
        // 读 greeting（VER NMETHODS METHODS…）：先读 2 字节定长头，再按 NMETHODS 读方法列表
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { head, _, _, _ in
            guard let head, head.count == 2, head[0] == 0x05, let nmethods = head.last,
                  nmethods >= 1, nmethods <= 255 else { connection.cancel(); return }
            connection.receive(minimumIncompleteLength: Int(nmethods), maximumLength: Int(nmethods)) { methods, _, _, _ in
                guard let methods, methods.count == Int(nmethods), methods.contains(0x00) else {
                    connection.cancel(); return
                }
                connection.send(content: Data([0x05, 0x00]), completion: .contentProcessed { _ in
                    // 读 CONNECT 请求头（固定 4 字节 + 变长地址 + 2 字节端口）
                    connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { head, _, _, _ in
                        guard let head, head.count == 4, head[1] == 0x01 else { connection.cancel(); return }
                        let addrLen: Int
                        switch head[3] {
                        case 0x01: addrLen = 4
                        case 0x03: addrLen = -1 // 域名：再读 1 字节长度
                        case 0x04: addrLen = 16
                        default: connection.cancel(); return
                        }
                        Self.readConnectTail(connection, addrLen: addrLen, webPort: webPort)
                    }
                })
            }
        }
    }

    private static func readConnectTail(_ connection: NWConnection, addrLen: Int, webPort: UInt16) {
        if addrLen < 0 {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { l, _, _, _ in
                guard let l, let n = l.first else { connection.cancel(); return }
                readConnectTail(connection, addrLen: Int(n), webPort: webPort)
            }
            return
        }
        connection.receive(minimumIncompleteLength: addrLen + 2, maximumLength: addrLen + 2) { _, _, _, _ in
            // 一律放行：回成功（绑定地址占位），后续字节与源站直通
            let reply = Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            connection.send(content: reply, completion: .contentProcessed { _ in
                Self.pipeToWeb(connection, webPort: webPort)
            })
        }
    }

    private static func pipeToWeb(_ client: NWConnection, webPort: UInt16) {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let web = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: webPort)!,
                               using: NWParameters(tls: nil, tcp: tcp))
        // client 已完成握手（处于就绪态）：state transitions 不会再回调，
        // 因此直接视为就绪，仅用 handler 监听后续失败
        let clientReady = true
        var webReady = false
        let queue = DispatchQueue(label: "pb-integration-socks-pipe")
        func maybePump() {
            guard clientReady, webReady else { return }
            pump(client, to: web, queue: queue)
            pump(web, to: client, queue: queue)
        }
        client.stateUpdateHandler = { state in
            if case .failed = state, case .cancelled = state { client.cancel() }
        }
        web.stateUpdateHandler = { if case .ready = $0 { webReady = true; maybePump() } }
        web.start(queue: queue)
        maybePump()
    }

    private static func pump(_ from: NWConnection, to: NWConnection, queue: DispatchQueue) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, eof, error in
            guard error == nil else { from.cancel(); to.cancel(); return }
            to.send(content: data, contentContext: eof ? .finalMessage : .defaultMessage, isComplete: true,
                    completion: .contentProcessed { _ in
                        if eof { from.cancel(); to.cancel(); return }
                        pump(from, to: to, queue: queue)
                    })
        }
    }

    func stop() { listener.cancel() }
}

/// 假 HTTP 代理上游：CONNECT 应 200 后直通源站；绝对格式请求直接回 200。
final class FakeHTTPUpstream: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16 = 0

    init(webPort: UInt16) throws {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            Self.serve(connection, webPort: webPort)
        }
        listener.start(queue: DispatchQueue(label: "pb-integration-http"))
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    private static func serve(_ connection: NWConnection, webPort: UInt16) {
        connection.start(queue: DispatchQueue(label: "pb-integration-http-conn"))
        var buffer = Data()
        func readHead() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, eof, error in
                guard error == nil, !eof, let data else { connection.cancel(); return }
                buffer.append(data)
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    readHead() // 头未完整：继续攒
                    return
                }
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                if head.hasPrefix("CONNECT") {
                    connection.send(content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8),
                                    completion: .contentProcessed { _ in
                                        Self.pipe(connection, webPort: webPort)
                                    })
                } else {
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: 25\r\nConnection: close\r\n\r\nPROXYBRIDGE-INTEGRATION-OK\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
        }
        readHead()
    }

    private static func pipe(_ client: NWConnection, webPort: UInt16) {
        let web = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: webPort)!,
                               using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options()))
        // client 已发出 200 应答（处于就绪态）：直接视为就绪，仅监听后续失败
        let clientReady = true
        var webReady = false
        let queue = DispatchQueue(label: "pb-integration-http-pipe")
        func maybePump() {
            guard clientReady, webReady else { return }
            pump(client, to: web, queue: queue)
            pump(web, to: client, queue: queue)
        }
        client.stateUpdateHandler = { _ in }
        web.stateUpdateHandler = { if case .ready = $0 { webReady = true; maybePump() } }
        web.start(queue: queue)
        maybePump()
    }

    private static func pump(_ from: NWConnection, to: NWConnection, queue: DispatchQueue) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, eof, error in
            guard error == nil else { from.cancel(); to.cancel(); return }
            to.send(content: data, contentContext: eof ? .finalMessage : .defaultMessage, isComplete: true,
                    completion: .contentProcessed { _ in
                        if eof { from.cancel(); to.cancel(); return }
                        pump(from, to: to, queue: queue)
                    })
        }
    }

    func stop() { listener.cancel() }
}

// MARK: - 场景装配

/// 本地探测替身：本地代理探测已由单元/冒烟覆盖，集成层聚焦真实隧道数据路径。
final class AlwaysVerifiedLocalProber: ProxyProbeExecuting, @unchecked Sendable {
    func probe(host: String, port: Int, protocol: ProxyProtocol) async -> ProbeOutcome {
        .verified(statusCode: 200)
    }
}

final class MemoryPasswordStore: PasswordStoring {
    private var storage: [UUID: String] = [:]
    private let lock = NSLock()
    func save(_ password: String, for id: UUID) { lock.lock(); storage[id] = password; lock.unlock() }
    func load(for id: UUID) -> String? { lock.lock(); defer { lock.unlock() }; return storage[id] }
    func delete(for id: UUID) { lock.lock(); storage[id] = nil; lock.unlock() }
    func exists(for id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return storage[id] != nil }
}

@MainActor
final class Scenario {
    let name: String
    private(set) var lastPhase: TunnelPhase?
    private(set) var snapshots: [TunnelSnapshot] = []
    private var phaseWaiter: ((TunnelPhase) -> Void)?

    init(name: String) { self.name = name }

    func run(
        sshPort: Int, user: String, keyPath: String,
        mode: ConnectionMode,
        upstreamProtocol: ProxyProtocol,
        fakeUpstreamPort: UInt16?,
        webPort: UInt16,
        host: String = "127.0.0.1",
        probeTargetOverride: String? = nil
    ) async -> Bool {
        // 远端转发端口（本机 sshd）：随机段选取（21000–25003，均在合法端口范围内），
        // 冲突导致失败时由整体退出码暴露
        let base = Int.random(in: 2_100...2_500) * 10
        var profile = ServerProfile(
            name: name, host: host, sshPort: sshPort,
            username: user, authMode: .identityFile, identityFilePath: keyPath,
            remotePort: base + 1, remoteSocksPort: base + 2, remoteHTTPPort: base + 3
        )
        profile.connectionMode = mode
        // 业务验证目标：动态/直连场景可用 PB_PROBE_TARGET 指向真实互联网目标
        // （fake 上游场景的链路终点是本地源站，不能用外部目标）
        profile.probeTargetURL = probeTargetOverride ?? "http://127.0.0.1:\(webPort)/probe"
        profile.httpAdapterEnabled = true

        var localEndpoint: LocalProxyEndpoint?
        if let fakeUpstreamPort {
            localEndpoint = LocalProxyEndpoint(
                host: "127.0.0.1", port: Int(fakeUpstreamPort),
                protocol: upstreamProtocol, origin: .manual
            )
        }

        let factory = FoundationSSHProcessFactory()
        let coordinator = SSHTunnelCoordinator(
            processFactory: factory,
            localProber: AlwaysVerifiedLocalProber(),
            remoteProber: SSHRemoteProbe(factory: factory),
            secrets: MemoryPasswordStore(),
            relayFactory: TCPRelayFactory(),
            httpEntryFactory: HTTPEntryRelayFactory()
        )
        coordinator.graceSeconds = 3
        coordinator.remoteProbeCooldown = 0

        let box = self
        coordinator.onEvent = { event in
            guard case .snapshot(let snap) = event else { return }
            box.record(snap)
        }

        coordinator.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: localEndpoint))
        let connected = await waitFor(phase: .connected, timeout: 40)
        guard connected else {
            print("FAIL  \(name)  未达到 connected：\(recentDetails())")
            coordinator.disconnect(profileID: profile.id)
            return false
        }
        let entryOK = lastSnapshot()?.httpAdapterVerified == true
            && lastSnapshot()?.httpAdapterStatus == .verified
        guard entryOK else {
            print("FAIL  \(name)  HTTP 入口未通过验证：\(lastSnapshot()?.httpAdapterDetail ?? "?")")
            coordinator.disconnect(profileID: profile.id)
            return false
        }

        // 断开 → 回到 idle 终态
        coordinator.disconnect(profileID: profile.id)
        let idle = await waitFor(phase: .idle, timeout: 10)
        coordinator.terminateAllSessions()
        guard idle else {
            print("FAIL  \(name)  断开后未回到 idle")
            return false
        }
        print("PASS  \(name)  端到端数据路径验证通过（\(mode == .staticForward ? "静态转发" : "动态 SOCKS5")）")
        return true
    }

    private func recentDetails() -> String {
        snapshots.suffix(3).map { "\($0.phase): \($0.humanReadableDetail.prefix(90))" }
            .joined(separator: " | ")
    }

    private func record(_ snap: TunnelSnapshot) {
        snapshots.append(snap)
        lastPhase = snap.phase
        phaseWaiter?(snap.phase)
    }

    private func lastSnapshot() -> TunnelSnapshot? { snapshots.last }

    /// askpass 取证：密码模式连接（真实 ssh + 开启 PasswordAuthentication 的测试 sshd），
    /// UI 输入路径注入一个必然错误的密码。通过标准：
    /// 1) 快速进入 authRequired（不是 90 秒超时、不是 /dev/tty 类错误——那意味着 helper 未被调用）；
    /// 2) 终态文案为「密码认证被拒绝」（密码送达 sshd 并被 PAM 拒绝）。
    func runAskpassRejection(sshPort: Int, user: String, host: String) async -> Bool {
        let base = Int.random(in: 2_600...2_900) * 10
        var profile = ServerProfile(
            name: name, host: host, sshPort: sshPort,
            username: user, authMode: .password,
            remotePort: base + 1, remoteSocksPort: base + 2, remoteHTTPPort: base + 3
        )
        profile.connectionMode = .reverseDynamic
        profile.httpAdapterEnabled = false

        let factory = FoundationSSHProcessFactory()
        let coordinator = SSHTunnelCoordinator(
            processFactory: factory,
            localProber: AlwaysVerifiedLocalProber(),
            remoteProber: SSHRemoteProbe(factory: factory),
            secrets: MemoryPasswordStore()
        )
        coordinator.graceSeconds = 8

        let box = self
        var prompts: [UUID] = []
        coordinator.onEvent = { event in
            switch event {
            case .snapshot(let snap): box.record(snap)
            case .passwordPromptRequested(let id): prompts.append(id)
            case .traffic: break
            }
        }

        let started = Date()
        coordinator.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: nil))
        // 密码必须发生在 ssh 启动之前：等 UI 输入请求
        let promptDeadline = Date().addingTimeInterval(10)
        while prompts.isEmpty && Date() < promptDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !prompts.isEmpty else {
            print("FAIL  \(name)  未在 ssh 启动前请求密码输入")
            coordinator.disconnect(profileID: profile.id)
            return false
        }
        coordinator.submitPassword(profileID: profile.id, password: "definitely-wrong-\(Int.random(in: 1000...9999))", remember: false)

        let authRequired = await waitFor(phase: .authRequired, timeout: 20)
        let elapsed = Date().timeIntervalSince(started)
        let detail = lastSnapshot()?.humanReadableDetail ?? ""
        coordinator.disconnect(profileID: profile.id)
        coordinator.terminateAllSessions()
        guard authRequired, elapsed < 30, detail.contains("密码认证被拒绝") else {
            print("FAIL  \(name)  耗时 \(Int(elapsed))s 终态：\(lastPhase.map(\.rawValue) ?? "?") / \(detail.prefix(120))")
            return false
        }
        print("PASS  \(name)  错密码 \(Int(elapsed))s 被快速拒绝（helper 已被真实 ssh 调用，密码已送达 sshd）")
        return true
    }

    private func waitFor(phase: TunnelPhase, timeout: TimeInterval) async -> Bool {
        if lastPhase == phase { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var settled = false
            phaseWaiter = { [weak self] current in
                guard !settled else { return }
                guard current == phase else { return }
                settled = true
                self?.phaseWaiter = nil
                continuation.resume(returning: true)
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !settled else { return }
                settled = true
                self.phaseWaiter = nil
                continuation.resume(returning: self.lastPhase == phase)
            }
        }
    }
}

// MARK: - 直连诊断（绕过 ssh）

/// 用 POSIX socket 直接对 Relay 做 SOCKS5 握手并取回源站响应（不经 ssh/sshd）。
func directRelayProbe(relayPort: UInt16, webPort: UInt16) async -> Bool {
    // 1) SOCKS5 握手（curl 同款：两种认证方法的 greeting）
    var sock = sockaddr_in()
    sock.sin_family = sa_family_t(AF_INET)
    sock.sin_port = (relayPort).bigEndian
    sock.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { print("FAIL  I0 裸Relay  socket 创建失败"); return false }
    defer { close(fd) }
    // 接收超时：防止无数据时 recv 无限阻塞
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let connectResult = withUnsafePointer(to: &sock) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        print("FAIL  I0 裸Relay  无法连接 Relay 监听端口 \(relayPort)")
        return false
    }
    func send(_ data: Data) -> Bool { data.withUnsafeBytes { buf in
        Darwin.send(fd, buf.baseAddress, buf.count, 0) == buf.count
    } }
    func recv(_ count: Int, timeoutSeconds: TimeInterval = 5) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        let result = buffer.withUnsafeMutableBytes { buf in
            Darwin.recv(fd, buf.baseAddress, count, 0)
        }
        guard result > 0 else { return nil }
        return Data(buffer.prefix(result))
    }
    guard send(Data([0x05, 0x02, 0x00, 0x02])),
          let choice = recv(2), choice == Data([0x05, 0x00]) else {
        print("FAIL  I0 裸Relay  SOCKS5 greeting 握手失败")
        return false
    }
    var request = Data([0x05, 0x01, 0x00, 0x03, UInt8("127.0.0.1".count)]) + Data("127.0.0.1".utf8)
    request.append(UInt8(webPort >> 8)); request.append(UInt8(webPort & 0xff))
    guard send(request), let reply = recv(4), reply.count == 4, reply[1] == 0x00 else {
        print("FAIL  I0 裸Relay  SOCKS5 CONNECT 应答失败：\(relayPort)")
        return false
    }
    _ = recv(6) // 绑定地址 + 端口（占位）
    // 2) 经隧道发 HTTP 请求并等待源站标记
    let http = Data("GET http://127.0.0.1:\(webPort)/probe HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
    guard send(http) else { print("FAIL  I0 裸Relay  请求发送失败"); return false }
    var payload = Data()
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline, !payload.contains(Data("PROXYBRIDGE-INTEGRATION-OK".utf8)) {
        guard let chunk = recv(4096, timeoutSeconds: 1) else { continue }
        payload.append(chunk)
    }
    guard payload.contains(Data("PROXYBRIDGE-INTEGRATION-OK".utf8)) else {
        print("FAIL  I0 裸Relay  源站响应未到达：\(String(decoding: payload.prefix(120), as: UTF8.self))")
        return false
    }
    print("PASS  I0 裸Relay  Relay → SOCKS5 上游 → 源站字节链路通畅")
    return true
}

// MARK: - 入口

@main
struct IntegrationEntry {
    @MainActor
    static func main() async {
        guard let sshPort = ProcessInfo.processInfo.environment["PB_SSH_PORT"].flatMap(Int.init),
              let user = ProcessInfo.processInfo.environment["PB_SSH_USER"],
              let keyPath = ProcessInfo.processInfo.environment["PB_SSH_KEY"] else {
            print("integration: 缺少 PB_SSH_PORT / PB_SSH_USER / PB_SSH_KEY 环境变量")
            exit(2)
        }
        let sshHost = ProcessInfo.processInfo.environment["PB_SSH_HOST"] ?? "127.0.0.1"
        let probeTarget = ProcessInfo.processInfo.environment["PB_PROBE_TARGET"]
        let askpassProof = ProcessInfo.processInfo.environment["PB_ASKPASS_PROOF"] == "1"

        print("== ProxyBridge 集成测试（真实 ssh，目标 \(sshHost):\(sshPort)）==")
        var passed = 0
        var failed = 0

    do {
        // 场景 0：绕过 ssh 的裸 Relay 数据路径（故障隔离：区分 Relay/假上游 vs 隧道转发）
        let web0 = try WebOrigin()
        let socks0 = try FakeSocksUpstream(webPort: web0.port)
        let relay0 = TCPRelay(profileID: UUID())
        let endpoint0 = LocalProxyEndpoint(host: "127.0.0.1", port: Int(socks0.port), protocol: .socks5, origin: .manual)
        let relayPort = try await relay0.start(port: 0, target: endpoint0)
        let i0 = await directRelayProbe(relayPort: relayPort, webPort: web0.port)
        if i0 { passed += 1 } else { failed += 1 }
        relay0.stop(); socks0.stop(); web0.stop()

        // 场景 1：静态转发 + SOCKS5 上游（HTTP 入口走 SOCKS5 翻译模式）
        let web1 = try WebOrigin()
        let socks = try FakeSocksUpstream(webPort: web1.port)
        let s1 = Scenario(name: "I1 静态转发·SOCKS5 上游")
        if await s1.run(sshPort: sshPort, user: user, keyPath: keyPath,
                        mode: .staticForward, upstreamProtocol: .socks5,
                        fakeUpstreamPort: socks.port, webPort: web1.port,
                        host: sshHost) { passed += 1 } else { failed += 1 }
        socks.stop(); web1.stop()

        // 场景 2：静态转发 + HTTP/Mixed 上游（HTTP 入口 pipe 模式）
        let web2 = try WebOrigin()
        let http = try FakeHTTPUpstream(webPort: web2.port)
        let s2 = Scenario(name: "I2 静态转发·HTTP 上游·入口 pipe")
        if await s2.run(sshPort: sshPort, user: user, keyPath: keyPath,
                        mode: .staticForward, upstreamProtocol: .mixed,
                        fakeUpstreamPort: http.port, webPort: web2.port,
                        host: sshHost) { passed += 1 } else { failed += 1 }
        http.stop(); web2.stop()

        // 场景 3：动态 SOCKS5 + HTTP 入口直连模式（无本地代理；
        // PB_PROBE_TARGET 可把业务目标指向真实互联网地址）
        let web3 = try WebOrigin()
        let s3 = Scenario(name: "I3 动态 SOCKS5·入口直连")
        if await s3.run(sshPort: sshPort, user: user, keyPath: keyPath,
                        mode: .reverseDynamic, upstreamProtocol: .http,
                        fakeUpstreamPort: nil, webPort: web3.port,
                        host: sshHost,
                        probeTargetOverride: probeTarget) { passed += 1 } else { failed += 1 }
        web3.stop()

        // 场景 4：askpass 密码投递取证（PB_ASKPASS_PROOF=1，仅本地测试 sshd）：
        // 真实 coordinator 全流程 + 故意错密码 → 期待快速 authRequired（密码认证被拒绝），
        // sshd VERBOSE 日志的 Failed password 由脚本侧 grep 作为「密码确实送达 sshd」的证据
        if askpassProof {
            let s4 = Scenario(name: "I4 askpass·错密码快速拒绝")
            if await s4.runAskpassRejection(sshPort: sshPort, user: user, host: "127.0.0.1") {
                passed += 1
            } else { failed += 1 }
        }
        } catch {
            print("FAIL  测试服务启动失败：\(error)")
            failed += 1
        }

        print("----------------------------------------")
        print("通过 \(passed) 项，失败 \(failed) 项")
        if failed > 0 {
            print("RESULT: FAIL")
            exit(1)
        }
        print("RESULT: PASS")
    }
}
