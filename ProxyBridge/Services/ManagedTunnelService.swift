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

    func connect(configuration: TunnelConfiguration) {
        let id = configuration.profile.id
        guard !isActive(profileID: id) else { return }
        desired[id] = configuration
        generations[id] = UUID()
        attempts[id] = 0
        connectedAt[id] = nil
        localDue[id] = nil
        remoteDue[id] = nil
        resumeIDs.remove(id)
        if sleeping {
            if configuration.profile.reconnectEnabled { resumeIDs.insert(id) }
            return
        }
        underlying.connect(configuration: configuration)
        startMonitor()
    }

    func disconnect(profileID: UUID) {
        desired[profileID] = nil
        generations[profileID] = nil
        retries.removeValue(forKey: profileID)?.cancel()
        resumeIDs.remove(profileID)
        localDue[profileID] = nil
        remoteDue[profileID] = nil
        connectedAt[profileID] = nil
        attempts[profileID] = nil
        underlying.disconnect(profileID: profileID)
        if snapshots[profileID]?.phase != .idle {
            var snapshot = TunnelSnapshot.idle(profileID)
            snapshot.humanReadableDetail = "已断开（用户手动操作）；不会自动重连"
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
        retries[profileID] != nil || resumeIDs.contains(profileID) || underlying.isActive(profileID: profileID)
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

    func terminateAllSessions() {
        monitor?.cancel(); monitor = nil
        retries.values.forEach { $0.cancel() }
        retries.removeAll(); desired.removeAll(); generations.removeAll(); resumeIDs.removeAll()
        snapshots.removeAll(); attempts.removeAll(); connectedAt.removeAll()
        localDue.removeAll(); remoteDue.removeAll()
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
        snapshots[id] = snapshot
        onEvent?(event)
        guard let configuration = desired[id], !sleeping else { return }
        if snapshot.phase == .connected || (snapshot.phase == .degraded && snapshot.sshProcessRunning) {
            if connectedAt[id] == nil { connectedAt[id] = Date() }
            if localDue[id] == nil { localDue[id] = Date().addingTimeInterval(localInterval) }
            if remoteDue[id] == nil { remoteDue[id] = Date().addingTimeInterval(remoteInterval) }
        }
        let unavailableLocal = snapshot.phase == .degraded && !snapshot.sshProcessRunning
        guard configuration.profile.reconnectEnabled, Self.shouldRetry(snapshot) || unavailableLocal else { return }
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
