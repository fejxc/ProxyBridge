import Foundation

/// 阶段 A 的隧道服务：按剧本驱动状态机，不启动任何 SSH 进程、不访问网络。
/// 所有事件进入日志时都带「演示」标记；UI 明确展示演示模式横幅。
@MainActor
final class MockTunnelService: TunnelService {
    var onEvent: (@MainActor (TunnelEvent) -> Void)?

    /// 每个阶段的演示耗时（秒），可注入缩短测试。
    var stepDelay: TimeInterval = 0.6

    /// 决定某个 profile 连接结局的剧本（测试注入用）。
    enum Outcome: Sendable {
        case connected
        case degradedLocalProxyDown
        case authRequired
        case remoteBindConflict
    }
    var outcome: Outcome = .connected

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var userStopped: Set<UUID> = []

    /// 测试观察：断开后是否还有事件产生（必须为 false，U13）。
    private(set) var eventsAfterUserStop: [TunnelSnapshot] = []

    func connect(configuration: TunnelConfiguration) {
        let id = configuration.profile.id
        // U14：同一 profile 重复连接请求只保留一个任务
        guard tasks[id] == nil else { return }
        userStopped.remove(id)

        tasks[id] = Task { @MainActor [weak self, id, configuration, stepDelay] in
            let delay = UInt64(stepDelay * 1_000_000_000)
            let emit: (TunnelSnapshot) -> Void = { snapshot in
                self?.onEvent?(.snapshot(snapshot))
            }
            var snap = TunnelSnapshot.idle(id)
            snap.phase = .checking
            snap.humanReadableDetail = "正在验证本地代理（演示）"
            emit(snap)
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }

            // checking 阶段结论：本地代理验证
            let localOK: Bool
            switch self.outcome {
            case .degradedLocalProxyDown:
                localOK = false
            default:
                localOK = configuration.localEndpoint != nil
            }
            if !localOK {
                snap.phase = .degraded
                snap.localProxyVerified = false
                snap.humanReadableDetail = "本地代理未通过验证（演示）：未解析到可用端点"
                emit(snap)
                self.finish(id)
                return
            }
            snap.localProxyVerified = true
            snap.phase = .connecting
            snap.humanReadableDetail = "正在建立 SSH 隧道（演示）"
            emit(snap)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            switch self.outcome {
            case .connected:
                snap.phase = .connected
                snap.sshProcessRunning = true
                snap.remoteProbeVerified = true
                snap.lastRemoteProbeAt = Date()
                snap.humanReadableDetail = "端到端验证通过（演示数据，非真实 SSH）"
                emit(snap)
            case .degradedLocalProxyDown:
                snap.phase = .degraded
                snap.sshProcessRunning = true
                snap.remoteProbeVerified = nil
                snap.humanReadableDetail = "隧道已建立，本地代理验证失败（演示）"
                emit(snap)
            case .authRequired:
                snap.phase = .authRequired
                snap.sshProcessRunning = false
                snap.remoteProbeVerified = nil
                snap.humanReadableDetail = "主机密钥或身份验证失败（演示）"
                emit(snap)
            case .remoteBindConflict:
                snap.phase = .error
                snap.sshProcessRunning = false
                snap.remoteProbeVerified = nil
                snap.humanReadableDetail = "远程监听端口被占用（演示）"
                emit(snap)
            }
            self.finish(id)
        }
    }

    func disconnect(profileID: UUID) {
        userStopped.insert(profileID)
        tasks[profileID]?.cancel()
        tasks[profileID] = nil
        var snap = TunnelSnapshot.idle(profileID)
        snap.phase = .disconnecting
        snap.humanReadableDetail = "正在停止（演示）"
        onEvent?(.snapshot(snap))
        var idle = TunnelSnapshot.idle(profileID)
        idle.humanReadableDetail = "用户手动断开（演示）；不会自动重连"
        onEvent?(.snapshot(idle))
    }

    func runHealthCheck(profileID: UUID) {
        // 演示：仅当处于终态时重新发一份带新验证时间的快照
        guard tasks[profileID] == nil else { return }
        var snap = TunnelSnapshot.idle(profileID)
        snap.phase = .connected
        snap.sshProcessRunning = true
        snap.localProxyVerified = true
        snap.remoteProbeVerified = true
        snap.lastRemoteProbeAt = Date()
        snap.humanReadableDetail = "手动检查完成（演示数据，非真实探测）"
        onEvent?(.snapshot(snap))
    }

    func isActive(profileID: UUID) -> Bool {
        tasks[profileID] != nil
    }

    /// 拦截事件以检测「断开后是否还有事件」（U13 语义）。
    /// Mock 的 onEvent 由 AppViewModel 设置；测试可通过包一层实现监听。
    private func finish(_ id: UUID) {
        tasks[id] = nil
    }

    /// 供测试直接判定：用户断开后是否有泄漏事件。
    func recordEventForAudit(_ snapshot: TunnelSnapshot) {
        if userStopped.contains(snapshot.profileId) {
            eventsAfterUserStop.append(snapshot)
        }
    }
}
