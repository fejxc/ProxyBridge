import Foundation

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
}
