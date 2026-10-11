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
    /// 每个 profile 最近一次下发的快照（健康检查只复核，不凭空造状态）。
    private var lastSnapshots: [UUID: TunnelSnapshot] = [:]

    func connect(configuration: TunnelConfiguration) {
        let id = configuration.profile.id
        // U14：同一 profile 重复连接请求只保留一个任务
        guard tasks[id] == nil else { return }

        tasks[id] = Task { @MainActor [weak self, id, configuration, stepDelay] in
            let delay = UInt64(stepDelay * 1_000_000_000)
            let emit: (TunnelSnapshot) -> Void = { snapshot in
                self?.lastSnapshots[id] = snapshot
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
                // 区分「未解析到端点（未发现）」与「端点验证失败」：
                // 未发现 → localProxyVerified 保持 nil（nil ≠ false ≠ true）
                snap.localProxyVerified = nil
                snap.humanReadableDetail = "未发现可用的本地代理端点（演示）：请在设置中手动指定"
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
        tasks[profileID]?.cancel()
        tasks[profileID] = nil
        var snap = TunnelSnapshot.idle(profileID)
        snap.phase = .disconnecting
        snap.humanReadableDetail = "正在停止（演示）"
        lastSnapshots[profileID] = snap
        onEvent?(.snapshot(snap))
        var idle = TunnelSnapshot.idle(profileID)
        idle.humanReadableDetail = "用户手动断开（演示）；不会自动重连"
        lastSnapshots[profileID] = idle
        onEvent?(.snapshot(idle))
    }

    /// 手动「检查连接」：只复核最近一次已知状态并刷新时间戳，
    /// 绝不把 error/authRequired/idle 翻转成绿色（诚实性红线）。
    func runHealthCheck(profileID: UUID) {
        guard tasks[profileID] == nil else { return }
        guard let last = lastSnapshots[profileID] else {
            var idle = TunnelSnapshot.idle(profileID)
            idle.humanReadableDetail = "检查完成：当前无活跃连接（演示）"
            onEvent?(.snapshot(idle))
            return
        }
        guard last.phase == .connected || last.phase == .degraded else {
            // 终态错误保持原样，只附检查说明
            var unchanged = last
            unchanged.humanReadableDetail = "检查完成：状态仍为「\(last.humanReadableDetail)」（演示，不改变结论）"
            onEvent?(.snapshot(unchanged))
            return
        }
        var rechecked = last
        rechecked.lastRemoteProbeAt = Date()
        rechecked.humanReadableDetail = "手动检查完成（演示数据，非真实探测；结论沿用上次验证）"
        lastSnapshots[profileID] = rechecked
        onEvent?(.snapshot(rechecked))
    }

    func isActive(profileID: UUID) -> Bool {
        tasks[profileID] != nil
    }

    private func finish(_ id: UUID) {
        tasks[id] = nil
    }
}
