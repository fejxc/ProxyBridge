import Foundation
import Network

extension SmokeMain {
    @MainActor
    static func relayLifecycleChecks() async {
        final class Factory: SSHProcessFactory, @unchecked Sendable {
            var handle = SmokeSSHHandle()
            var arguments: [String] = []
            func make(arguments: [String], environment: [String: String]) -> any SSHProcessHandle { self.arguments = arguments; return handle }
        }
        let profile = ServerProfile(name: "relay", host: "test.invalid", sshPort: 22, username: "test", remotePort: 7890)
        let endpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .manual)
        let factory = Factory()
        let service = SSHTunnelCoordinator(processFactory: factory, localProber: SmokeLocalProber(outcome: .verified(statusCode: 200)),
            remoteProber: SmokeRemoteProber(outcome: .verified(statusCode: 200)), secrets: InMemoryPasswordStore(), relayFactory: TCPRelayFactory())
        service.graceSeconds = 0.01
        var state: TunnelSnapshot?
        var traffic: TrafficSnapshot?
        service.onEvent = { event in
            switch event {
            case .snapshot(let value): state = value
            case .traffic(let value): traffic = value
            case .passwordPromptRequested: break
            }
        }
        service.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: endpoint))
        _ = await waitSmokeUntil { state?.phase == .connected && traffic?.relayPort != nil }
        let port = traffic?.relayPort ?? 0
        check("L01", "Relay ready 后 SSH 只转发到回环 Relay 端口", port != 0 && factory.arguments.contains("127.0.0.1:7890:127.0.0.1:\(port)") && port != UInt16(endpoint.port))
        let firstID = traffic?.sessionID

        // L08：本地代理端点变化 → 实测新端点 → Relay 无缝切换 → 按新协议重验远端
        let sshHandleBefore = factory.handle
        let changedEndpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 7898, protocol: .socks5, origin: .systemSOCKS)
        service.retargetLocalEndpoint(profileID: profile.id, endpoint: changedEndpoint)
        _ = await waitSmokeUntil(timeout: 3) {
            state?.activeLocalEndpoint?.id == changedEndpoint.id && state?.phase == .connected
        }
        check("L08", "本地代理端点变化：Relay 无缝切换 + 远端重验 + SSH/Relay 不重启",
              state?.activeLocalEndpoint?.port == 7898
                && state?.phase == .connected
                && (state?.humanReadableDetail.contains("无缝切换") ?? false)
                && traffic?.sessionID == firstID
                && traffic?.isRunning == true
                && factory.handle === sshHandleBefore)
        service.disconnect(profileID: profile.id)
        _ = await waitSmokeUntil { traffic?.isRunning == false }
        check("L02", "SSH 手动断开关闭 Relay 并归零速率", traffic?.isRunning == false && traffic?.uploadRate == 0 && traffic?.downloadRate == 0)
        factory.handle = SmokeSSHHandle()
        service.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: endpoint))
        _ = await waitSmokeUntil { traffic?.sessionID != firstID && state?.phase == .connected }
        check("L03", "重连产生新的流量会话", traffic?.sessionID != firstID && traffic?.uploadBytes == 0)
        service.terminateAllSessions()
        _ = await waitSmokeUntil { traffic?.isRunning == false }
        check("L04", "休眠/退出批量清理仍收到最终统计", traffic?.isRunning == false)

        let occupied = TCPRelay(profileID: UUID())
        let locked = try? await occupied.start(port: 0, target: endpoint)
        if let locked {
            let badFactory = Factory()
            let blocked = SSHTunnelCoordinator(processFactory: badFactory, localProber: SmokeLocalProber(outcome: .verified(statusCode: 200)),
                remoteProber: SmokeRemoteProber(outcome: .verified(statusCode: 200)), secrets: InMemoryPasswordStore(), relayFactory: TCPRelayFactory())
            var badProfile = profile; badProfile.relayPort = Int(locked)
            var failure: TunnelSnapshot?
            blocked.onEvent = { if case .snapshot(let value) = $0 { failure = value } }
            blocked.connect(configuration: TunnelConfiguration(profile: badProfile, localEndpoint: endpoint))
            _ = await waitSmokeUntil { failure?.phase == .error }
            check("L05", "端口冲突时不启动 SSH，不显示已连接", failure?.phase == .error && !badFactory.handle.started)
            blocked.terminateAllSessions(); occupied.stop()
        } else { check("L05", "端口冲突时不启动 SSH，不显示已连接", false) }
        var old = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        old.removeValue(forKey: "relayPort")
        let restored = try? JSONDecoder().decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: old))
        check("L06", "旧配置无 Relay 字段时兼容自动端口", restored?.relayPort == nil && restored?.id == profile.id)
        var invalid = profile; invalid.relayPort = 70000
        check("L07", "配置拒绝无效 Relay 端口", !ServerProfileRule.validate(invalid).isValid)
    }

    // MARK: 真实 socket 级动态切换（本地代理波动场景的最小复现）

    /// 真实回显上游：把收到的内容加「标记:」前缀原样返回（用回显内容证明命中了哪个上游）。
    final class EchoUpstream {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "smoke.echo")
        private let marker: String
        private(set) var port: UInt16 = 0

        init?(marker: String) {
            self.marker = marker
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            guard let listener = try? NWListener(using: parameters) else { return nil }
            self.listener = listener
        }

        /// 返回 false = 监听器未能就绪。
        func start() -> Bool {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .waiting: ready.signal()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.echo(connection)
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 3) == .success,
                  case .ready = listener.state,
                  let port = listener.port?.rawValue, port != 0 else { return false }
            self.port = port
            return true
        }

        private func echo(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, eof, error in
                guard let self else { connection.cancel(); return }
                if let data, !data.isEmpty, error == nil {
                    connection.send(content: Data("\(self.marker):".utf8) + data, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } else {
                    connection.cancel()
                }
            }
        }

        func stop() { listener.cancel() }
    }

    /// 经真实 TCP 连接穿过 Relay 发一段内容，返回上游的回显（nil = 超时/失败）。
    static func roundtrip(port: UInt16, payload: String) async -> String? {
        let once = OnceBox()
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "smoke.retarget-client")
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let connection = NWConnection(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                using: NWParameters(tls: nil, tcp: tcp)
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in })
                case .failed, .waiting:
                    if once.run({ continuation.resume(returning: nil) }) { connection.cancel() }
                default: break
                }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if once.run({ continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) }) }) {
                    connection.cancel()
                } else if error != nil {
                    connection.cancel()
                }
            }
            queue.asyncAfter(deadline: .now() + 3) {
                if once.run({ continuation.resume(returning: nil) }) { connection.cancel() }
            }
            connection.start(queue: queue)
        }
    }

    /// 只允许 resume 一次的盒子（回调可能从多个状态路径到达）。
    final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return false }
            done = true
            body()
            return true
        }
    }

    @MainActor
    static func relayRetargetChecks() async {
        // 场景：本地代理从端口 A 漂移到端口 B。Relay 监听端口不变（SSH 转发不受影响），
        // 上游目标从 A 切到 B；用回显标记证明切换前后分别命中 A 与 B。
        guard let upstreamA = EchoUpstream(marker: "A"), let upstreamB = EchoUpstream(marker: "B") else {
            check("L09", "回显上游启动（Network.framework）", false)
            return
        }
        defer { upstreamA.stop(); upstreamB.stop() }
        guard upstreamA.start(), upstreamB.start() else {
            check("L09", "回显上游启动（Network.framework）", false)
            return
        }
        check("L09", "回显上游启动（Network.framework）", true)
        let endpointA = LocalProxyEndpoint(host: "127.0.0.1", port: Int(upstreamA.port), protocol: .http, origin: .manual)
        let endpointB = LocalProxyEndpoint(host: "127.0.0.1", port: Int(upstreamB.port), protocol: .http, origin: .manual)

        let relay = TCPRelay(profileID: UUID())
        guard let relayPort = try? await relay.start(port: 0, target: endpointA), relayPort != 0 else {
            check("L10", "Relay 启动并指向上游 A", false)
            relay.stop()
            return
        }
        let before = await roundtrip(port: relayPort, payload: "ping-before")
        check("L10", "切换前：经 Relay 数据命中上游 A", before?.hasPrefix("A:") == true)

        relay.retarget(to: endpointB)
        let after = await roundtrip(port: relayPort, payload: "ping-after")
        check("L11", "切换后：同一 Relay 端口的新连接命中上游 B", after?.hasPrefix("B:") == true)
        relay.stop()
    }
}
