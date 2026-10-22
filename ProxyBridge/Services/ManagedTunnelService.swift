import Foundation

/// Runtime policy wraps the process coordinator; only explicit connection intent
/// may survive a network failure or sleep. Passwords remain in the coordinator.
@MainActor
final class ManagedTunnelService: TunnelService {
    var onEvent: (@MainActor (TunnelEvent) -> Void)?
    var resolveEndpoint: ((ServerProfile) -> LocalProxyEndpoint?)?
    private let underlying: any TunnelService
    private var desired: [UUID: TunnelConfiguration] = [:]
    private var snapshots: [UUID: TunnelSnapshot] = [:]
    private var retries: [UUID: Task<Void, Never>] = [:]
    /// 业务连续失败触发的受控重建任务；与错误退避重试分开，避免语义混用。
    private var recoveryTasks: [UUID: Task<Void, Never>] = [:]
    /// 5 分钟滚动窗口内的业务失败重建时间。
    private var businessRecoveryAttempts: [UUID: [Date]] = [:]
    /// 最近一次业务失败重建时间，用于冷却。
    private var lastBusinessRecoveryAt: [UUID: Date] = [:]
    /// 每台服务器的自愈状态迁移短历史；只存决策元数据，不存业务请求内容。
    private var recoveryHistory: [UUID: [TunnelRecoveryDecision]] = [:]
    private var generations: [UUID: UUID] = [:]
    private var attempts: [UUID: Int] = [:]
    private var connectedAt: [UUID: Date] = [:]
    private var localDue: [UUID: Date] = [:]
    private var remoteDue: [UUID: Date] = [:]
    private var resumeIDs: Set<UUID> = []
    private var settings = AppSettings.defaults()
    private var monitor: Task<Void, Never>?
    private var sleeping = false
    private var suppressEvents = false
    // Injectable durations let regression tests exercise real scheduling quickly.
    var retryBaseSeconds: Double = 1
    var maximumRetrySeconds: Double = 60
    var monitorTickSeconds: Double = 1
    var localIntervalOverride: Double?
    var remoteIntervalOverride: Double?
    var wakeDelaySeconds: Double = 2
    /// 远端端口冲突的自动重试窗口（秒）：旧 sshd 释放端口通常需要 1–3 分钟；
    /// 窗口过后仍冲突视为真实占用/禁转发，停止重试转为终态指引。测试注入更短值。
    var remoteBindConflictWindowSeconds: Double = 180
    /// 连续业务硬失败阈值；三个独立周期可排除单次网络抖动。
    var businessFailureThreshold = 3
    /// 两次业务失败重建的最小间隔；测试注入更短值。
    var businessRecoveryCooldownSeconds: Double = 60
    /// 滚动窗口大小，与 maximumBusinessRecoveries 共同防重连风暴。
    var businessRecoveryWindowSeconds: Double = 300
    /// 窗口内最多自动重建次数；超过后继续探测并提示需人工/等环境恢复。
    var maximumBusinessRecoveries = 2
    /// 各 profile 首次检测到端口冲突的时间。
    private var conflictSince: [UUID: Date] = [:]

    init(underlying: any TunnelService) {
        self.underlying = underlying
        underlying.onEvent = { [weak self] event in self?.receive(event) }
    }

    static func retryDelay(attempt: Int, base: Double = 1, maximum: Double = 60) -> Double {
        min(maximum, base * pow(2, Double(min(max(attempt, 0), 20))))
    }

    static func shouldRetry(_ snapshot: TunnelSnapshot) -> Bool {
        guard snapshot.phase == .error else { return false }
        let detail = snapshot.humanReadableDetail
        guard !detail.contains("密码"), !detail.contains("主机密钥") else { return false }
        return ["无法解析 SSH 主机名", "网络不可达", "连接 SSH 主机超时", "SSH 端口拒绝连接", "SSH 进程异常退出"].contains { detail.contains($0) }
    }

    /// 远端转发端口绑定冲突（常见：上次连接的 sshd 未释放端口，1–3 分钟自愈）。
    /// 与 shouldRetry 的永久配置错误不同：这类冲突限时自动重试（见 conflictWindow）。
    static func isRemoteBindConflict(_ detail: String) -> Bool {
        detail.contains("监听失败：端口可能被占用")
    }

    /// 本地 Relay 端口冲突（固定 Relay 端口被其他进程占用）。
    /// 与远端冲突同一窗口语义：限时重试给占用方释放的机会，窗口过后转终态。
    static func isLocalRelayConflict(_ detail: String) -> Bool {
        detail.contains("本地 Relay 监听失败") || detail.contains("本地 Relay 无法启动")
    }

    func connect(configuration: TunnelConfiguration) {
        let id = configuration.profile.id
        guard !isActive(profileID: id) else { return }
        desired[id] = configuration
        generations[id] = UUID()
        attempts[id] = 0
        connectedAt[id] = nil
        localDue[id] = nil
        remoteDue[id] = nil
        conflictSince[id] = nil // 新的连接意图：端口冲突窗口重新计时
        recoveryHistory[id] = nil // 新连接意图从干净轨迹开始
        resumeIDs.remove(id)
        if sleeping {
            if configuration.profile.reconnectEnabled { resumeIDs.insert(id) }
            return
        }
        underlying.connect(configuration: configuration)
        startMonitor()
    }

    func disconnect(profileID: UUID) {
        performDisconnect(profileID: profileID, systemReason: nil)
    }

    /// 系统原因断开（网络重建/模式升级）：清理逻辑与用户断开一致，文案如实。
    func disconnectForSystemReason(profileID: UUID, reason: String) {
        performDisconnect(profileID: profileID, systemReason: reason)
    }

    private func performDisconnect(profileID: UUID, systemReason: String?) {
        desired[profileID] = nil
        generations[profileID] = nil
        retries.removeValue(forKey: profileID)?.cancel()
        recoveryTasks.removeValue(forKey: profileID)?.cancel()
        businessRecoveryAttempts.removeValue(forKey: profileID)
        lastBusinessRecoveryAt.removeValue(forKey: profileID)
        resumeIDs.remove(profileID)
        localDue[profileID] = nil
        remoteDue[profileID] = nil
        connectedAt[profileID] = nil
        attempts[profileID] = nil
        conflictSince[profileID] = nil
        if let reason = systemReason {
            underlying.disconnectForSystemReason(profileID: profileID, reason: reason)
        } else {
            underlying.disconnect(profileID: profileID)
        }
        if snapshots[profileID]?.phase != .idle {
            var snapshot = TunnelSnapshot.idle(profileID)
            snapshot.humanReadableDetail = systemReason ?? "已断开（用户手动操作）；不会自动重连"
            snapshot.lastRecoveryDecision = nil
            snapshots[profileID] = snapshot
            onEvent?(.snapshot(snapshot))
        }
        if desired.isEmpty { monitor?.cancel(); monitor = nil }
    }

    func updateRuntimeSettings(_ settings: AppSettings) {
        self.settings = settings.sanitized
        let now = Date()
        for id in desired.keys {
            localDue[id] = now.addingTimeInterval(localInterval)
            remoteDue[id] = now.addingTimeInterval(remoteInterval)
        }
        startMonitor()
    }

    func updateReconnectPreference(profileID: UUID, enabled: Bool, rememberPassword: Bool) {
        guard var configuration = desired[profileID] else { return }
        configuration.profile.reconnectEnabled = enabled
        configuration.profile.rememberPassword = rememberPassword
        desired[profileID] = configuration
        if !enabled {
            resumeIDs.remove(profileID)
            if let task = retries.removeValue(forKey: profileID) {
                task.cancel()
                generations[profileID] = UUID()
                var snapshot = snapshots[profileID] ?? .idle(profileID)
                snapshot.phase = .error
                snapshot.humanReadableDetail = "自动重连已关闭，请手动连接"
                snapshots[profileID] = snapshot
                onEvent?(.snapshot(snapshot))
            }
        }
    }

    func runHealthCheck(profileID: UUID) {
        guard !sleeping else { return }
        localDue[profileID] = Date().addingTimeInterval(localInterval)
        remoteDue[profileID] = Date().addingTimeInterval(remoteInterval)
        underlying.runHealthCheck(profileID: profileID)
    }

    func runLocalHealthCheck(profileID: UUID) {
        guard !sleeping else { return }
        underlying.runLocalHealthCheck(profileID: profileID)
    }

    /// 本地代理端点变化：同步期望配置（后续自动重连沿用新端点）并转发给协调器。
    func retargetLocalEndpoint(profileID: UUID, endpoint: LocalProxyEndpoint) {
        guard desired[profileID] != nil else { return }
        desired[profileID]?.localEndpoint = endpoint
        guard !sleeping else { return }
        underlying.retargetLocalEndpoint(profileID: profileID, endpoint: endpoint)
    }

    func isActive(profileID: UUID) -> Bool {
        retries[profileID] != nil || recoveryTasks[profileID] != nil
            || resumeIDs.contains(profileID) || underlying.isActive(profileID: profileID)
    }
    func submitPassword(profileID: UUID, password: String, remember: Bool) {
        desired[profileID]?.profile.rememberPassword = remember
        underlying.submitPassword(profileID: profileID, password: password, remember: remember)
    }
    func cancelPasswordPrompt(profileID: UUID) { disconnect(profileID: profileID) }

    func prepareForSleep() {
        guard !sleeping else { return }
        sleeping = true
        monitor?.cancel(); monitor = nil
        resumeIDs = Set(desired.keys.filter {
            desired[$0]?.profile.reconnectEnabled == true && (isActive(profileID: $0)
                || snapshots[$0]?.phase == .checking || snapshots[$0]?.phase == .connecting)
        })
        for (id, task) in retries { task.cancel(); generations[id] = UUID() }
        retries.removeAll()
        for (id, task) in recoveryTasks { task.cancel(); generations[id] = UUID() }
        recoveryTasks.removeAll()
        suppressEvents = true
        underlying.terminateAllSessions()
        suppressEvents = false
        for id in desired.keys {
            if snapshots[id]?.phase == .authRequired || snapshots[id]?.phase == .error { continue }
            var snapshot = TunnelSnapshot.idle(id)
            if resumeIDs.contains(id) {
                snapshot.phase = .reconnecting
                snapshot.humanReadableDetail = "Mac 已休眠，唤醒后恢复连接"
            } else { snapshot.humanReadableDetail = "Mac 已休眠；自动重连未开启或连接需要处理" }
            snapshots[id] = snapshot
            onEvent?(.snapshot(snapshot))
        }
    }

    func resumeAfterWake() {
        guard sleeping else { return }
        sleeping = false
        let ids = resumeIDs
        resumeIDs.removeAll()
        for id in ids { scheduleRetry(id: id, delay: wakeDelaySeconds, reason: "Mac 已唤醒") }
        startMonitor()
    }

    /// 网络路径恢复（Wi-Fi 重连/VPN 起来）：绕过退避立即重连，不再等 SSH ServerAlive 超时。
    /// 只作用于 desired 中且开启自动重连的 profile：退避中的取消等待；活跃的回收重建。
    /// 未开自动重连的会话保持原语义（死亡后进入终态，不自动恢复）。
    func handleNetworkRestoration() {
        guard !sleeping else { return }
        for id in desired.keys {
            guard desired[id]?.profile.reconnectEnabled == true else { continue }
            if retries.removeValue(forKey: id) != nil {
                reconnectNow(id: id, reason: "网络已恢复")
            } else if isActive(profileID: id) {
                underlying.disconnectForSystemReason(profileID: id, reason: "网络已恢复")
                reconnectNow(id: id, reason: "网络已恢复")
            }
        }
        startMonitor()
    }

    /// 立即按期望配置重连：重新解析端点、重置健康检查排程与退避计数。
    private func reconnectNow(id: UUID, reason: String) {
        guard !sleeping, var configuration = desired[id], configuration.profile.reconnectEnabled else { return }
        if let resolve = resolveEndpoint { configuration.localEndpoint = resolve(configuration.profile) }
        desired[id] = configuration
        generations[id] = UUID()
        attempts[id] = 0
        connectedAt[id] = nil
        localDue[id] = nil
        remoteDue[id] = nil
        var snapshot = snapshots[id] ?? .idle(id)
        snapshot.phase = .reconnecting
        snapshot.sshProcessRunning = false
        snapshot.localProxyVerified = nil
        snapshot.remoteProbeVerified = nil
        snapshot.consecutiveRemoteFailures = 0
        snapshot.humanReadableDetail = "\(reason)；正在重建连接"
        snapshots[id] = snapshot
        onEvent?(.snapshot(snapshot))
        underlying.connect(configuration: configuration)
    }

    func terminateAllSessions() {
        monitor?.cancel(); monitor = nil
        retries.values.forEach { $0.cancel() }
        recoveryTasks.values.forEach { $0.cancel() }
        retries.removeAll(); recoveryTasks.removeAll()
        desired.removeAll(); generations.removeAll(); resumeIDs.removeAll()
        snapshots.removeAll(); attempts.removeAll(); connectedAt.removeAll()
        localDue.removeAll(); remoteDue.removeAll(); conflictSince.removeAll()
        businessRecoveryAttempts.removeAll(); lastBusinessRecoveryAt.removeAll()
        recoveryHistory.removeAll()
        suppressEvents = true
        underlying.terminateAllSessions()
        suppressEvents = false
    }

    private var localInterval: Double { localIntervalOverride ?? Double(settings.localCheckIntervalSeconds) }
    private var remoteInterval: Double { remoteIntervalOverride ?? Double(settings.remoteCheckIntervalSeconds) }

    private func receive(_ event: TunnelEvent) {
        if case .traffic = event { onEvent?(event); return }
        guard !suppressEvents else { return }
        guard case .snapshot(let snapshot) = event else { onEvent?(event); return }
        let id = snapshot.profileId
        var decorated = snapshot
        // 协调器快照不携带历史；系统重建经过 idle 时也不能丢失已执行轨迹。
        if decorated.recoveryHistory.isEmpty {
            decorated.recoveryHistory = snapshots[id]?.recoveryHistory ?? []
        }
        // 协调器只提供证据；恢复决策由策略层附加，跨健康快照保留。
        if decorated.lastRecoveryDecision == nil,
           let previous = snapshots[id]?.lastRecoveryDecision {
            if decorated.phase == .connected {
                decorated.lastRecoveryDecision = previous.succeeded()
                decorated.appendRecoveryDecision(decorated.lastRecoveryDecision!)
            } else if decorated.phase == .idle && previous.state == .executed {
                // 系统重建会短暂经过 idle；保留“已执行”，等新连接给出最终结论。
                decorated.lastRecoveryDecision = previous
            } else if decorated.phase != .idle {
                decorated.lastRecoveryDecision = previous
            }
        }
        recoveryHistory[id] = decorated.recoveryHistory
        snapshots[id] = decorated
        onEvent?(.snapshot(decorated))
        guard let configuration = desired[id], !sleeping else { return }
        if snapshot.phase == .connected || (snapshot.phase == .degraded && snapshot.sshProcessRunning) {
            if connectedAt[id] == nil { connectedAt[id] = Date() }
            if localDue[id] == nil { localDue[id] = Date().addingTimeInterval(localInterval) }
            if remoteDue[id] == nil { remoteDue[id] = Date().addingTimeInterval(remoteInterval) }
            conflictSince[id] = nil // 连接成功：端口冲突跟踪复位
        }
        // 端口冲突（远端旧 sshd 未释放 / 本地 Relay 端口被占，通常 1–3 分钟内可自愈）：
        // 窗口内自动重试，窗口过后仍冲突 → 视为真实占用/禁转发，保持终态指引（不再无限重试）。
        // 过期时间戳不清空：否则下一个冲突事件会再开新窗口、永远停不下来；
        // 复位只发生在连接成功、非冲突事件或用户重新发起连接时。
        let bindConflict = snapshot.phase == .error
            && (Self.isRemoteBindConflict(snapshot.humanReadableDetail)
                || Self.isLocalRelayConflict(snapshot.humanReadableDetail))
        if bindConflict {
            let now = Date()
            if let since = conflictSince[id] {
                if now.timeIntervalSince(since) >= remoteBindConflictWindowSeconds {
                    return
                }
            } else {
                conflictSince[id] = now
            }
        } else if snapshot.phase != .error {
            conflictSince[id] = nil
        }
        if snapshot.phase == .degraded, snapshot.sshProcessRunning {
            maybeScheduleBusinessRecovery(id: id, snapshot: snapshot)
            if recoveryTasks[id] != nil || businessFailureBudgetExhausted(snapshot) { return }
        }
        let unavailableLocal = snapshot.phase == .degraded && !snapshot.sshProcessRunning
        guard configuration.profile.reconnectEnabled, Self.shouldRetry(snapshot) || unavailableLocal || bindConflict else { return }
        if let connected = connectedAt[id], Date().timeIntervalSince(connected) >= 60 { attempts[id] = 0 }
        connectedAt[id] = nil
        let attempt = attempts[id] ?? 0
        attempts[id] = min(attempt + 1, 20)
        scheduleRetry(id: id, delay: Self.retryDelay(attempt: attempt, base: retryBaseSeconds, maximum: maximumRetrySeconds), reason: snapshot.humanReadableDetail)
    }

    private func scheduleRetry(id: UUID, delay: Double, reason: String) {
        guard !sleeping, retries[id] == nil, desired[id]?.profile.reconnectEnabled == true else { return }
        let generation = generations[id] ?? UUID()
        generations[id] = generation
        var snapshot = snapshots[id] ?? .idle(id)
        snapshot.phase = .reconnecting
        snapshot.sshProcessRunning = false
        snapshot.localProxyVerified = nil
        snapshot.remoteProbeVerified = nil
        snapshot.consecutiveRemoteFailures = 0
        snapshot.humanReadableDetail = "\(reason)；\(String(format: "%.1f", delay)) 秒后重连"
        snapshots[id] = snapshot
        retries[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) }
            catch { return }
            guard let self, !self.sleeping, self.generations[id] == generation,
                  var configuration = self.desired[id], configuration.profile.reconnectEnabled else { return }
            self.retries[id] = nil
            if let resolve = self.resolveEndpoint { configuration.localEndpoint = resolve(configuration.profile) }
            self.desired[id] = configuration
            self.localDue[id] = nil; self.remoteDue[id] = nil
            self.underlying.connect(configuration: configuration)
        }
        onEvent?(.snapshot(snapshot))
    }

    /// SSH 进程还活着、但业务通路连续明确失败：受控重建。
    /// 只统计 connectionFailure/notProxy；探测超时或缺 curl 是不确定结论，不触发。
    private func maybeScheduleBusinessRecovery(id: UUID, snapshot: TunnelSnapshot) {
        guard recoveryTasks[id] == nil,
              snapshot.sshProcessRunning,
              snapshot.consecutiveRemoteFailures >= businessFailureThreshold else { return }

        let now = Date()
        businessRecoveryAttempts[id]?.removeAll { now.timeIntervalSince($0) >= businessRecoveryWindowSeconds }
        if (businessRecoveryAttempts[id]?.count ?? 0) >= maximumBusinessRecoveries {
            var budgetSnapshot = snapshot
            budgetSnapshot.humanReadableDetail += "；已连续失败，自动重建窗口预算用尽，将继续探测"
            let decision = TunnelRecoveryDecision(
                scope: .remotePath,
                action: .probeOnly,
                state: .budgetExhausted,
                reason: snapshot.humanReadableDetail,
                decidedAt: now,
                nextActionAt: nil,
                consecutiveFailures: snapshot.consecutiveRemoteFailures,
                remainingRecoveries: 0
            )
            budgetSnapshot.appendRecoveryDecision(decision)
            snapshots[id] = budgetSnapshot
            onEvent?(.snapshot(budgetSnapshot))
            return
        }

        let last = lastBusinessRecoveryAt[id]
        let delay = last.map { max(0, businessRecoveryCooldownSeconds - now.timeIntervalSince($0)) } ?? 0.05
        businessRecoveryAttempts[id, default: []].append(now)
        lastBusinessRecoveryAt[id] = now
        scheduleBusinessRecovery(
            id: id,
            delay: delay,
            reason: snapshot.humanReadableDetail,
            consecutiveFailures: snapshot.consecutiveRemoteFailures,
            remainingRecoveries: maximumBusinessRecoveries - (businessRecoveryAttempts[id]?.count ?? 0)
        )
    }

    private func businessFailureBudgetExhausted(_ snapshot: TunnelSnapshot) -> Bool {
        let id = snapshot.profileId
        guard snapshot.phase == .degraded, snapshot.sshProcessRunning,
              snapshot.consecutiveRemoteFailures >= businessFailureThreshold else { return false }
        let now = Date()
        businessRecoveryAttempts[id]?.removeAll { now.timeIntervalSince($0) >= businessRecoveryWindowSeconds }
        return (businessRecoveryAttempts[id]?.count ?? 0) >= maximumBusinessRecoveries
    }

    private func scheduleBusinessRecovery(
        id: UUID,
        delay: Double,
        reason: String,
        consecutiveFailures: Int,
        remainingRecoveries: Int
    ) {
        guard !sleeping, recoveryTasks[id] == nil, desired[id]?.profile.reconnectEnabled == true else { return }
        let generation = generations[id] ?? UUID()
        generations[id] = generation
        var snapshot = snapshots[id] ?? .idle(id)
        snapshot.phase = .reconnecting
        snapshot.sshProcessRunning = false
        snapshot.localProxyVerified = nil
        snapshot.remoteProbeVerified = nil
        snapshot.consecutiveRemoteFailures = 0
        snapshot.humanReadableDetail = "业务通路连续失败；正在受控重建（\(String(format: "%.1f", delay)) 秒后执行）"
        let decision = TunnelRecoveryDecision(
            scope: .remotePath,
            action: .rebuildTunnel,
            state: .scheduled,
            reason: reason,
            decidedAt: Date(),
            nextActionAt: Date().addingTimeInterval(delay),
            consecutiveFailures: consecutiveFailures,
            remainingRecoveries: remainingRecoveries
        )
        snapshot.appendRecoveryDecision(decision)
        snapshots[id] = snapshot
        onEvent?(.snapshot(snapshot))

        recoveryTasks[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) }
            catch { return }
            guard let self, !self.sleeping, self.generations[id] == generation,
                  var configuration = self.desired[id], configuration.profile.reconnectEnabled else { return }
            self.recoveryTasks[id] = nil
            if let resolve = self.resolveEndpoint { configuration.localEndpoint = resolve(configuration.profile) }
            self.desired[id] = configuration
            self.localDue[id] = nil
            self.remoteDue[id] = nil
            // 系统断开会经过 idle；先把排程改为“已执行”，避免面板闪回旧计划。
            if var snapshot = self.snapshots[id],
               let decision = snapshot.lastRecoveryDecision,
               decision.state == .scheduled {
                let executed = decision.executed()
                snapshot.appendRecoveryDecision(executed)
                self.snapshots[id] = snapshot
                self.onEvent?(.snapshot(snapshot))
            }
            // 先显式释放旧 Session，再连接；coordinator 的 connect 用新 Session 替换旧终态。
            self.underlying.disconnectForSystemReason(profileID: id, reason: "业务通路连续失败")
            self.underlying.connect(configuration: configuration)
        }
    }

    private func startMonitor() {
        guard monitor == nil, !sleeping, !desired.isEmpty else { return }
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let tick = self?.monitorTickSeconds else { return }
                do { try await Task.sleep(nanoseconds: UInt64(max(tick, 0.01) * 1_000_000_000)) }
                catch { return }
                self?.checkDue()
            }
        }
    }

    private func checkDue() {
        let now = Date()
        for id in desired.keys {
            guard let snapshot = snapshots[id], snapshot.sshProcessRunning,
                  snapshot.phase == .connected || snapshot.phase == .degraded else { continue }
            if let connected = connectedAt[id], now.timeIntervalSince(connected) >= 60 { attempts[id] = 0 }
            if now >= remoteDue[id] ?? .distantFuture {
                remoteDue[id] = now.addingTimeInterval(remoteInterval)
                localDue[id] = now.addingTimeInterval(localInterval)
                underlying.runHealthCheck(profileID: id)
            } else if now >= localDue[id] ?? .distantFuture {
                localDue[id] = now.addingTimeInterval(localInterval)
                underlying.runLocalHealthCheck(profileID: id)
            }
        }
    }
}
