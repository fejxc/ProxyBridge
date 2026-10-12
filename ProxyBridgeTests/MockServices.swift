import Foundation
#if canImport(ProxyBridge)
@testable import ProxyBridge
#endif

/// 测试专用隧道替身，不启动 SSH 进程，不编入应用。
@MainActor
final class MockTunnelService: TunnelService {
    var onEvent: (@MainActor (TunnelEvent) -> Void)?

    /// 每个阶段的测试耗时（秒），可注入缩短测试。
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
            snap.humanReadableDetail = "正在验证本地代理（测试）"
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
                snap.humanReadableDetail = "未发现可用的本地代理端点（测试）：请在设置中手动指定"
                emit(snap)
                self.finish(id)
                return
            }
            snap.localProxyVerified = true
            snap.phase = .connecting
            snap.humanReadableDetail = "正在建立 SSH 隧道（测试）"
            emit(snap)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            switch self.outcome {
            case .connected:
                snap.phase = .connected
                snap.sshProcessRunning = true
                snap.remoteProbeVerified = true
                snap.lastRemoteProbeAt = Date()
                snap.humanReadableDetail = "端到端验证通过（测试数据，非真实 SSH）"
                emit(snap)
            case .degradedLocalProxyDown:
                snap.phase = .degraded
                snap.sshProcessRunning = true
                snap.remoteProbeVerified = nil
                snap.humanReadableDetail = "隧道已建立，本地代理验证失败（测试）"
                emit(snap)
            case .authRequired:
                snap.phase = .authRequired
                snap.sshProcessRunning = false
                snap.remoteProbeVerified = nil
                snap.humanReadableDetail = "主机密钥或身份验证失败（测试）"
                emit(snap)
            case .remoteBindConflict:
                snap.phase = .error
                snap.sshProcessRunning = false
                snap.remoteProbeVerified = nil
                snap.humanReadableDetail = "远程监听端口被占用（测试）"
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
        snap.humanReadableDetail = "正在停止（测试）"
        lastSnapshots[profileID] = snap
        onEvent?(.snapshot(snap))
        var idle = TunnelSnapshot.idle(profileID)
        idle.humanReadableDetail = "用户手动断开（测试）；不会自动重连"
        lastSnapshots[profileID] = idle
        onEvent?(.snapshot(idle))
    }

    /// 手动「检查连接」：只复核最近一次已知状态并刷新时间戳，
    /// 绝不把 error/authRequired/idle 翻转成绿色（诚实性红线）。
    func runHealthCheck(profileID: UUID) {
        guard tasks[profileID] == nil else { return }
        guard let last = lastSnapshots[profileID] else {
            var idle = TunnelSnapshot.idle(profileID)
            idle.humanReadableDetail = "检查完成：当前无活跃连接（测试）"
            onEvent?(.snapshot(idle))
            return
        }
        guard last.phase == .connected || last.phase == .degraded else {
            // 终态错误保持原样，只附检查说明
            var unchanged = last
            unchanged.humanReadableDetail = "检查完成：状态仍为「\(last.humanReadableDetail)」（测试，不改变结论）"
            onEvent?(.snapshot(unchanged))
            return
        }
        var rechecked = last
        rechecked.lastRemoteProbeAt = Date()
        rechecked.humanReadableDetail = "手动检查完成（测试数据，非真实探测；结论沿用上次验证）"
        lastSnapshots[profileID] = rechecked
        onEvent?(.snapshot(rechecked))
    }

    func isActive(profileID: UUID) -> Bool {
        tasks[profileID] != nil
    }

    func terminateAllSessions() {
        for id in Array(tasks.keys) {
            tasks[id]?.cancel()
            tasks[id] = nil
        }
        lastSnapshots.removeAll()
    }

    func submitPassword(profileID: UUID, password: String, remember: Bool) {}
    func cancelPasswordPrompt(profileID: UUID) {
        // 测试：取消等价于断开
        disconnect(profileID: profileID)
    }

    private func finish(_ id: UUID) {
        tasks[id] = nil
    }
}

// MARK: - Mock（测试数据，绝不声称读取了系统；测试与离线测试用）

/// 测试检测器。返回固定的「示例」候选，日志与 UI 均标注测试；
/// 存在的意义是让 UI/ViewModel/持久化链路在无网络下可完整演练。
@MainActor
final class MockProxyDetector: ProxyDetectorService {
    var onStateChange: (@MainActor (ProxyDetectionState) -> Void)?

    private var state = ProxyDetectionState()
    private var task: Task<Void, Never>?

    /// 模拟耗时（秒）。
    var simulatedLatency: TimeInterval = 0.8

    func startObservingSystemChanges() -> Bool {
        // 测试模式不订阅系统变化，返回 true 保持调用方语义
        true
    }

    func detect() {
        task?.cancel()
        state.isScanning = true
        state.lastScanAt = Date()
        emit()
        task = Task { [weak self, latency = simulatedLatency] in
            try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishScan()
        }
    }

    private func finishScan() {
        state.isScanning = false
        let http = LocalProxyEndpoint(
            host: "127.0.0.1", port: 7897, protocol: .http,
            origin: .systemHTTP, verifiedAt: Date()
        )
        let socks = LocalProxyEndpoint(
            host: "127.0.0.1", port: 7897, protocol: .socks5,
            origin: .systemSOCKS, verifiedAt: Date()
        )
        state.candidates = [
            ProxyCandidate(endpoint: http, capability: .verified, note: "测试数据：未发起真实探测"),
            ProxyCandidate(endpoint: socks, capability: .verified, note: "测试数据：未发起真实探测"),
        ]
        state.limitations = [
            "当前为测试数据：未读取本机系统代理，也未发起任何网络探测。",
        ]
        state.systemProxyActiveButUnresolved = false
        emit()
    }

    private func emit() {
        onStateChange?(state)
    }
}

/// 测试/冒烟实现：内存字典（进程内隔离，不触碰用户钥匙串）。
final class InMemoryPasswordStore: PasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    init() {}

    func save(_ password: String, for profileID: UUID) {
        lock.lock()
        storage[profileID] = password
        lock.unlock()
    }

    func load(for profileID: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[profileID]
    }

    func delete(for profileID: UUID) {
        lock.lock()
        storage.removeValue(forKey: profileID)
        lock.unlock()
    }

    func exists(for profileID: UUID) -> Bool {
        load(for: profileID) != nil
    }
}
