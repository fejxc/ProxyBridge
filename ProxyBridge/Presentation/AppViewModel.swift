import Foundation
import AppKit
import Observation

/// 设置窗口的四个分区。
enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case servers, proxy, logs, general
    var id: String { rawValue }
}

/// 应用级 ViewModel：持有全部 UI 状态，桥接服务与持久化。
/// View 层只读状态、调用方法，不包含业务逻辑。
@MainActor
@Observable
final class AppViewModel {
    // MARK: - 依赖（注入）

    let profileStore: ProfileRepository
    let settingsStore: AppSettingsStore
    let tunnel: TunnelService
    let proxyDetector: ProxyDetectorService
    let logStore: LogStore
    /// SSH 密码的安全存储（生产 Keychain；测试内存实现）。
    let trafficStore = TrafficStore()
    let secrets: any PasswordStoring

    // MARK: - 状态

    private(set) var profiles: [ServerProfile] = []
    private(set) var currentProfileId: UUID?
    private(set) var snapshots: [UUID: TunnelSnapshot] = [:]
    private(set) var detection = ProxyDetectionState()
    /// 密码模式：等待用户输入 SSH 密码的 profile（nil = 无待输入）。
    private(set) var pendingPasswordProfileId: UUID?
    var pendingPasswordProfileName: String? {
        pendingPasswordProfileId.flatMap { id in profiles.first { $0.id == id }?.name }
    }
    private(set) var settings: AppSettings = .defaults()
    var settingsTab: SettingsTab = .servers
    var showSettingsWindow: (() -> Void)?

    private var document: ProfilesDocument = .empty()
    private let systemServices: (any AppSystemIntegrating)?
    private(set) var loginLaunchEnabled = false
    private(set) var loginStatusDescription = "仅安装后的应用可以设置登录启动"
    private(set) var notificationStatusDescription = "尚未授权通知"
    private(set) var changingLoginState = false
    private var passwordPromptQueue: [UUID] = []
    var degradedNotificationDelaySeconds: Double = 60
    private var pendingStartupProfiles: Set<UUID> = []
    private var loginErrorMessage: String?
    private var notificationGenerations: [UUID: UUID] = [:]
    private var notificationTasks: [UUID: Task<Void, Never>] = [:]
    private var notificationPolicy = ConnectionNotificationPolicy()
    private var connectionEndpoints: [UUID: LocalProxyEndpoint] = [:]
    /// App 退出清理观察者（PRD F05：退出时清理自身 SSH 子进程）。
    private var terminateObserver: (any NSObjectProtocol)?

    // MARK: - 初始化

    init(
        profileStore: ProfileRepository,
        settingsStore: AppSettingsStore,
        tunnel: TunnelService,
        proxyDetector: ProxyDetectorService,
        logStore: LogStore,
        secrets: any PasswordStoring,
        systemServices: (any AppSystemIntegrating)? = nil
    ) {
        self.profileStore = profileStore
        self.settingsStore = settingsStore
        self.tunnel = tunnel
        self.proxyDetector = proxyDetector
        self.logStore = logStore
        self.secrets = secrets
        self.systemServices = systemServices

        bootstrap()
    }

    /// 生产装配：本地代理检测与 SSH 隧道均为真实实现
    /// （SCDynamicStore + curl 实测；/usr/bin/ssh 参数数组直启）。
    static func live() -> AppViewModel {
        AppViewModel(
            profileStore: ProfileRepository(),
            settingsStore: AppSettingsStore(),
            tunnel: ManagedTunnelService(underlying: SSHTunnelCoordinator(
                processFactory: FoundationSSHProcessFactory(),
                localProber: CurlProxyProbe(),
                remoteProber: SSHRemoteProbe(factory: FoundationSSHProcessFactory()),
                secrets: KeychainPasswordStore(),
                relayFactory: TCPRelayFactory()
            )),
            proxyDetector: LocalProxyDetector(
                provider: SCDynamicStoreProxyProvider(),
                prober: CurlProxyProbe(),
                monitor: SCDynamicStoreChangeMonitor()
            ),
            logStore: LogStore(),
            secrets: KeychainPasswordStore(),
            systemServices: AppSystemServices()
        )
    }

    private func bootstrap() {
        settings = settingsStore.load()
        if settingsStore.lastLoadWasCorrupted {
            logStore.append(raw: "settings.json 无法解析，已回退默认设置（文件保留原样，便于人工排查）", level: .error)
        }

        do {
            document = try profileStore.load()
        } catch ProfileRepositoryError.corrupted(let underlying) {
            do {
                let side = try profileStore.quarantineCorruptFile()
                logStore.append(
                    raw: "配置文件无法解析（\(LogRedaction.sanitize(underlying))），已备份至 \(side.lastPathComponent) 并以空配置启动",
                    level: .error
                )
            } catch {
                logStore.append(raw: "配置文件无法解析，且备份失败：\(error.localizedDescription)", level: .error)
            }
            document = .empty()
        } catch {
            logStore.append(raw: "读取配置失败：\(error.localizedDescription)", level: .error)
            document = .empty()
        }

        profiles = document.profiles
        currentProfileId = document.currentProfileId ?? profiles.first?.id
        for p in profiles {
            snapshots[p.id] = TunnelSnapshot.idle(p.id)
        }

        pendingStartupProfiles = Set(profiles.filter(\.connectAtLaunch).map(\.id))
        wireServices()
        tunnel.updateRuntimeSettings(settings)
        systemServices?.onSleep = { [weak self] in
            self?.pendingPasswordProfileId = nil
            self?.passwordPromptQueue.removeAll()
            self?.tunnel.prepareForSleep()
        }
        systemServices?.onWake = { [weak self] in
            self?.proxyDetector.detect()
            self?.tunnel.resumeAfterWake()
        }
        if let runtime = tunnel as? ManagedTunnelService {
            runtime.resolveEndpoint = { [weak self] profile in
                guard let self else { return nil }
                let endpoint = self.endpointValue(of: EndpointResolver.resolve(profile: profile, detection: self.detection))
                self.connectionEndpoints[profile.id] = endpoint
                return endpoint
            }
        }
        refreshSystemStatus()

        // App 退出：终止全部本 App 拥有的 ssh 子进程（幂等、只杀自己的 PID）
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main 保证主线程；同步清理（Task 跳跃可能晚于进程退出）
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }

        logStore.append(
            raw: "ProxyBridge 启动",
            level: .info
        )
        if profiles.isEmpty {
            logStore.append(raw: "尚未配置服务器，请打开设置添加", level: .info)
        }
        proxyDetector.startObservingSystemChanges()
        proxyDetector.detect()
    }

    private func wireServices() {
        tunnel.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .traffic(let snapshot):
                if self.profiles.contains(where: { $0.id == snapshot.profileID }) { self.trafficStore.update(snapshot) }
            case .snapshot(let snap):
                self.applySnapshot(snap)
            case .passwordPromptRequested(let profileId):
                if self.pendingPasswordProfileId == nil { self.pendingPasswordProfileId = profileId }
                else if self.pendingPasswordProfileId != profileId && !self.passwordPromptQueue.contains(profileId) {
                    self.passwordPromptQueue.append(profileId)
                }
                self.logStore.append(
                    raw: "服务器需要 SSH 密码：请在面板中输入（密码在内存中使用，勾选记住才写入本机钥匙串）",
                    level: .info,
                    profileId: profileId
                )
            }
        }
        proxyDetector.onStateChange = { [weak self] state in
            guard let self else { return }
            self.detection = state
            if !state.isScanning {
                let ids = self.pendingStartupProfiles
                self.pendingStartupProfiles.removeAll()
                for profile in self.profiles where ids.contains(profile.id) { self.connect(profile: profile) }
            }
        }
    }

    // MARK: - 派生状态

    var currentProfile: ServerProfile? {
        profiles.first { $0.id == currentProfileId }
    }

    var currentSnapshot: TunnelSnapshot {
        guard let id = currentProfileId, let snap = snapshots[id] else {
            return TunnelSnapshot(profileId: UUID(), phase: .idle, localProxyVerified: nil,
                                  sshProcessRunning: false, remoteProbeVerified: nil,
                                  lastRemoteProbeAt: nil, humanReadableDetail: "未配置服务器")
        }
        return snap
    }

    /// 菜单栏面板主状态（无配置时给出引导文案）。
    var overallPresentation: StatusPresentation {
        if profiles.isEmpty {
            return StatusPresentation(title: "未配置", detail: "打开设置添加第一台服务器", tone: .gray)
        }
        return TunnelStatusPresentation.overall(for: currentSnapshot)
    }

    var healthTriad: (local: HealthCheckDisplay, ssh: HealthCheckDisplay, remote: HealthCheckDisplay) {
        TunnelStatusPresentation.healthTriad(for: currentSnapshot)
    }

    /// 当前应使用的本地代理端点描述（面板「本地代理」行）。
    var resolvedEndpointDescription: String {
        guard let profile = currentProfile else { return "—" }
        return EndpointResolver.describe(
            EndpointResolver.resolve(profile: profile, detection: detection),
            preferred: profile.preferredProtocol
        )
    }

    /// 菜单栏图标（SF Symbol，按色调区分）。
    var menuBarSymbolName: String {
        switch overallPresentation.tone {
        case .gray: return "arrow.left.arrow.right"
        case .blue: return "arrow.left.arrow.right.circle"
        case .green: return "arrow.left.arrow.right.circle.fill"
        case .orange: return "exclamationmark.arrow.circlepath"
        case .red: return "exclamationmark.triangle"
        }
    }

    /// 主按钮形态。
    enum PrimaryAction: Equatable {
        case connect          // 显示「连接」
        case disconnect       // 显示「断开连接」
        case busy(String)     // 禁用 + 转圈
    }

    var primaryAction: PrimaryAction {
        switch currentSnapshot.phase {
        case .idle, .error, .authRequired:
            return currentProfile == nil ? .busy("未选择服务器") : .connect
        case .checking, .connecting, .reconnecting, .disconnecting:
            return .busy("处理中…")
        case .connected, .degraded:
            return .disconnect
        }
    }

    // MARK: - Profile 管理

    func selectProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        // 切换选择即离开「新建草稿」编辑态，编辑器需跟随展示被选服务器
        editorIsNewDraft = false
        currentProfileId = id
        persist()
        logStore.append(raw: "切换当前服务器：\(profiles.first { $0.id == id }?.name ?? "?")", level: .info, profileId: id)
    }

    /// 新 profile 的编辑初值。不含真实服务器默认值（约束：示例不得内置为默认）。
    func makeNewProfileDraft() -> ServerProfile {
        ServerProfile(
            name: "新服务器 \(profiles.count + 1)",
            host: "",
            sshPort: 22,
            username: "",
            remotePort: 7890
        )
    }

    /// 侧栏「添加服务器」：置位「新草稿」信号；编辑器据此本地建立未保存草稿。
    /// 保存时才入列落盘。
    private(set) var editorIsNewDraft = false

    func requestCreateProfile() {
        editorIsNewDraft = true
    }

    /// 编辑器保存草稿。校验失败的非法配置拒绝保存（U06「拒绝保存」半边）。
    @discardableResult
    func saveDraftProfile(_ profile: ServerProfile) -> Bool {
        let validation = ServerProfileRule.validate(profile)
        guard validation.isValid else {
            logStore.append(
                raw: "服务器「\(profile.name)」配置未通过校验，已拒绝保存：\(validation.errors.joined(separator: "；"))",
                level: .error, profileId: profile.id
            )
            return false
        }
        editorIsNewDraft = false
        upsertProfile(profile)
        currentProfileId = profile.id
        persist()
        if let conflict = remotePortConflictDescription(for: profile) {
            logStore.append(raw: "端口冲突提示：\(conflict)", level: .warning, profileId: profile.id)
        }
        return true
    }

    /// F02「端口冲突提示」：同主机同远程监听端口会互相顶掉远端监听。
    func remotePortConflictDescription(for profile: ServerProfile) -> String? {
        let conflicts = profiles.filter {
            $0.id != profile.id && $0.host == profile.host && $0.remotePort == profile.remotePort
        }
        guard !conflicts.isEmpty else { return nil }
        return "「\(profile.name)」与 \(conflicts.map(\.name).joined(separator: "、")) 使用同一 SSH 主机的远程端口 \(profile.remotePort)，同时连接会互相失败"
    }

    /// 放弃草稿。
    func discardDraft() {
        editorIsNewDraft = false
    }

    /// 新增或更新。若目标 profile 存在活跃连接，则按规范提示需要重连。
    func upsertProfile(_ profile: ServerProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            let old = profiles[idx]
            profiles[idx] = profile
            let connectionRelevantChange = old.host != profile.host
                || old.sshPort != profile.sshPort
                || old.username != profile.username
                || old.authMode != profile.authMode
                || old.identityFilePath != profile.identityFilePath
                || old.remotePort != profile.remotePort
                || old.relayPort != profile.relayPort
            if connectionRelevantChange,
               let snap = snapshots[profile.id], snap.phase == .connected || snap.phase == .degraded {
                var updated = snap
                updated.phase = .degraded
                updated.humanReadableDetail = "配置已修改，需断开后重连才能生效（当前隧道仍使用旧配置）"
                snapshots[profile.id] = updated
                logStore.append(raw: "服务器「\(profile.name)」连接参数已修改，需要手动重连", level: .warning, profileId: profile.id)
            }
            logStore.append(raw: "已保存服务器「\(profile.name)」", level: .success, profileId: profile.id)
        } else {
            profiles.append(profile)
            snapshots[profile.id] = TunnelSnapshot.idle(profile.id)
            if currentProfileId == nil { currentProfileId = profile.id }
            logStore.append(raw: "新增服务器「\(profile.name)」", level: .success, profileId: profile.id)
        }
        tunnel.updateReconnectPreference(profileID: profile.id, enabled: profile.reconnectEnabled, rememberPassword: profile.rememberPassword)
        persist()
    }

    /// 删除前的安全检查：活跃连接先断开（由本 App 管理的进程）。
    func deleteProfile(_ id: UUID) {
        if tunnel.isActive(profileID: id) {
            tunnel.disconnect(profileID: id)
        }
        secrets.delete(for: id) // 清掉可能记住的密码
        let name = profiles.first { $0.id == id }?.name ?? "?"
        profiles.removeAll { $0.id == id }
        snapshots[id] = nil
        trafficStore.remove(id)
        pendingStartupProfiles.remove(id)
        notificationTasks.removeValue(forKey: id)?.cancel()
        notificationGenerations[id] = nil
        notificationPolicy.reset(profileID: id)
        finishPasswordPrompt(profileID: id)
        if currentProfileId == id {
            currentProfileId = profiles.first?.id
        }
        logStore.append(raw: "已删除服务器「\(name)」", level: .warning, profileId: id)
        persist()
    }

    // MARK: - 连接动作

    func connect() {
        guard let profile = currentProfile else { return }
        connect(profile: profile)
    }

    private func connect(profile: ServerProfile) {
        guard ServerProfileRule.validate(profile).isValid else {
            logStore.append(raw: "服务器「\(profile.name)」配置未通过校验，已阻止连接", level: .error, profileId: profile.id)
            var snap = snapshots[profile.id] ?? TunnelSnapshot.idle(profile.id)
            snap.phase = .error
            snap.humanReadableDetail = "配置校验未通过，请打开设置修正"
            snapshots[profile.id] = snap
            return
        }
        let resolved = EndpointResolver.resolve(profile: profile, detection: detection)
        if case .none(let reason) = resolved {
            logStore.append(raw: "未解析到可用本地代理：\(reason)。可在设置中手动指定。", level: .warning, profileId: profile.id)
        }
        let config = TunnelConfiguration(profile: profile, localEndpoint: endpointValue(of: resolved))
        connectionEndpoints[profile.id] = config.localEndpoint
        logStore.append(
            raw: "请求连接「\(profile.name)」",
            level: .info,
            profileId: profile.id
        )
        tunnel.connect(configuration: config)
    }

    func disconnect() {
        guard let profile = currentProfile else { return }
        pendingStartupProfiles.remove(profile.id)
        logStore.append(raw: "用户手动断开「\(profile.name)」", level: .info, profileId: profile.id)
        tunnel.disconnect(profileID: profile.id)
    }

    /// 用户提交 SSH 密码（转发给隧道服务；勾选记住时存入本机钥匙串）。
    func submitPassword(_ password: String, remember: Bool) {
        guard let id = pendingPasswordProfileId else { return }
        finishPasswordPrompt(profileID: id)
        if remember {
            secrets.save(password, for: id)
            if var p = profiles.first(where: { $0.id == id }), !p.rememberPassword {
                p.rememberPassword = true
                upsertProfile(p)
            }
        }
        tunnel.submitPassword(profileID: id, password: password, remember: remember)
    }

    /// 是否有已记住的密码（编辑器展示用）。
    func hasStoredPassword(for profileID: UUID) -> Bool {
        secrets.exists(for: profileID)
    }

    /// 忘记密码：清除钥匙串并关闭记住开关。
    func forgetStoredPassword() {
        guard let profile = currentProfile else { return }
        secrets.delete(for: profile.id)
        var p = profile
        if p.rememberPassword {
            p.rememberPassword = false
            upsertProfile(p)
        }
        logStore.append(raw: "已清除记住的 SSH 密码（钥匙串）", level: .info, profileId: profile.id)
    }

    func cancelPasswordPrompt() {
        guard let id = pendingPasswordProfileId else { return }
        finishPasswordPrompt(profileID: id)
        tunnel.cancelPasswordPrompt(profileID: id)
    }

    private func finishPasswordPrompt(profileID: UUID) {
        passwordPromptQueue.removeAll { $0 == profileID }
        if pendingPasswordProfileId == profileID {
            pendingPasswordProfileId = nil
            while !passwordPromptQueue.isEmpty {
                let next = passwordPromptQueue.removeFirst()
                if profiles.contains(where: { $0.id == next }) { pendingPasswordProfileId = next; break }
            }
        }
    }

    func runHealthCheck() {
        guard let profile = currentProfile else { return }
        if !tunnel.isActive(profileID: profile.id) && snapshots[profile.id]?.phase == .idle {
            logStore.append(
                raw: "尚未连接，请先连接再检查",
                level: .warning,
                profileId: profile.id
            )
            return
        }
        logStore.append(raw: "开始检查连接：本地代理 / SSH 隧道 / 远端代理", level: .info, profileId: profile.id)
        tunnel.runHealthCheck(profileID: profile.id)
    }

    // MARK: - 代理检测

    func redetectProxy() {
        logStore.append(raw: "开始重新检测本地代理（读取系统设置 + curl 实测，验证目标 www.example.com）", level: .info)
        proxyDetector.detect()
    }

    /// 应用手动代理。返回错误列表（空 = 成功）。
    @discardableResult
    func applyManualEndpoint(host: String, port: Int, protocol: ProxyProtocol) -> [String] {
        let errors = LocalProxyEndpointRule.validate(host: host, port: port)
        guard errors.isEmpty, let profileId = currentProfileId, var profile = currentProfile else {
            return errors.isEmpty ? ["没有可用的当前服务器"] : errors
        }
        let endpoint = LocalProxyEndpoint(
            host: host.trimmingCharacters(in: .whitespaces).lowercased(),
            port: port,
            protocol: `protocol`,
            origin: .manual
        )
        profile.proxySelectionMode = .manual
        profile.manualEndpoint = endpoint
        upsertProfile(profile)
        // 手动端点必须重新验证：清空既有验证结论，活跃隧道降级待查
        if var snap = snapshots[profileId], snap.phase == .connected || snap.phase == .degraded {
            snap.localProxyVerified = nil
            snap.remoteProbeVerified = nil
            if snap.phase == .connected { snap.phase = .degraded }
            snap.humanReadableDetail = "本地代理端点已变更，待重新验证"
            snapshots[profileId] = snap
        }
        logStore.append(
            raw: "应用手动代理 \(endpoint.displayEndpoint)（\(endpoint.protocol.displayName)）；连接前将实测验证",
            level: .info, profileId: profileId
        )
        return []
    }

    func setProxySelectionMode(_ mode: ProxySelectionMode) {
        guard var profile = currentProfile else { return }
        guard profile.proxySelectionMode != mode else { return }
        profile.proxySelectionMode = mode
        upsertProfile(profile)
        logStore.append(raw: "本地代理模式切换为「\(mode.displayName)」", level: .info, profileId: profile.id)
    }

    /// 设置当前 profile 的首选协议（http/socks5，仍受实测能力约束）。
    func setPreferredProtocol(_ proto: ProxyProtocol) {
        guard var profile = currentProfile else { return }
        guard profile.preferredProtocol != proto else { return }
        profile.preferredProtocol = proto
        upsertProfile(profile)
    }

    // MARK: - 通用设置

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        settings = next.sanitized
        tunnel.updateRuntimeSettings(settings)
        if !settings.showNotifications {
            notificationTasks.values.forEach { $0.cancel() }
            notificationTasks.removeAll()
            notificationGenerations.removeAll()
            systemServices?.clearNotifications()
        }
        do {
            try settingsStore.save(settings)
        } catch {
            logStore.append(raw: "保存设置失败：\(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - 复制

    /// 远端使用命令（按当前实测/选定协议）。无 profile 或端口非法时返回 nil（防御持久化脏数据触发崩溃）。
    func remoteCommandText() -> String? {
        guard let profile = currentProfile else { return nil }
        guard (1...65_535).contains(profile.remotePort) else {
            logStore.append(raw: "服务器「\(profile.name)」的远程端口 \(profile.remotePort) 非法，已拒绝生成命令；请修正配置", level: .error, profileId: profile.id)
            return nil
        }
        let activeEndpoint = snapshots[profile.id]?.sshProcessRunning == true
            ? connectionEndpoints[profile.id] : nil
        let endpoint = activeEndpoint ?? endpointValue(of: EndpointResolver.resolve(profile: profile, detection: detection))
        let proto = endpoint?.protocol ?? profile.preferredProtocol
        return RemoteCommandTemplate.clipboardText(
            remotePort: profile.remotePort,
            protocol: proto,
            remoteVerified: snapshots[profile.id]?.remoteProbeVerified
        )
    }

    func copyRemoteCommandToPasteboard() {
        guard let text = remoteCommandText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logStore.append(raw: "已复制远端代理使用命令到剪贴板", level: .info, profileId: currentProfileId)
    }

    func copyLogsToPasteboard() {
        let text = logStore.exportText(redacted: settings.redactLogsOnCopy)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logStore.append(raw: "已复制日志（\(settings.redactLogsOnCopy ? "脱敏" : "未脱敏——包含主机与用户名")）", level: .info)
    }

    /// 菜单栏「查看日志」/设置按钮跳转。
    func openSettings(tab: SettingsTab) {
        settingsTab = tab
        showSettingsWindow?()
    }

    // MARK: - 内部

    private func endpointValue(of resolved: EndpointResolver.Resolved) -> LocalProxyEndpoint? {
        switch resolved {
        case .manual(let ep), .auto(let ep): return ep
        case .none: return nil
        }
    }

    private func applySnapshot(_ snap: TunnelSnapshot) {
        let previous = snapshots[snap.profileId]
        snapshots[snap.profileId] = snap
        considerNotification(snap)
        if [.idle, .error, .authRequired].contains(snap.phase) {
            finishPasswordPrompt(profileID: snap.profileId)
        }
        if !snap.sshProcessRunning && [.idle, .error, .authRequired].contains(snap.phase) {
            connectionEndpoints[snap.profileId] = nil
        }
        guard previous?.phase != snap.phase || previous?.humanReadableDetail != snap.humanReadableDetail else { return }
        let name = profiles.first { $0.id == snap.profileId }?.name ?? "?"
        let level: LogLevel
        switch snap.phase {
        case .connected: level = .success
        case .degraded, .authRequired, .error: level = .warning
        default: level = .info
        }
        let phrase = TunnelStatusPresentation.overall(for: snap)
        let detail = snap.humanReadableDetail.isEmpty ? phrase.detail : snap.humanReadableDetail
        logStore.append(
            raw: "「\(name)」状态：\(phrase.title)（\(detail)）",
            level: level,
            profileId: snap.profileId
        )
    }

    func refreshSystemStatus() {
        guard let services = systemServices else { return }
        loginLaunchEnabled = services.loginState == .enabled || services.loginState == .requiresApproval
        loginStatusDescription = services.loginState.description + (loginErrorMessage.map { "；" + $0 } ?? "")
        Task { @MainActor [weak self] in
            do { self?.notificationStatusDescription = try await services.notificationPermission(request: false).description }
            catch { self?.notificationStatusDescription = "无法读取通知授权：\(error.localizedDescription)" }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard let services = systemServices, !changingLoginState else { return }
        changingLoginState = true
        loginErrorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.changingLoginState = false; self.refreshSystemStatus() }
            do {
                try await services.setLoginEnabled(enabled)
                let requested = services.loginState == .enabled || services.loginState == .requiresApproval
                self.updateSettings { $0.launchAtLoginRequested = requested }
                self.logStore.append(raw: services.loginState.description, level: .info)
            } catch {
                self.loginErrorMessage = "登录启动设置失败：\(error.localizedDescription)"
                self.loginStatusDescription = self.loginErrorMessage!
                self.logStore.append(raw: self.loginStatusDescription, level: .error)
            }
        }
    }

    func requestNotificationPermission() {
        guard let services = systemServices else { return }
        Task { @MainActor [weak self] in
            do { self?.notificationStatusDescription = try await services.notificationPermission(request: true).description }
            catch { self?.notificationStatusDescription = "通知授权失败：\(error.localizedDescription)" }
        }
    }

    private func considerNotification(_ snapshot: TunnelSnapshot) {
        let id = snapshot.profileId
        if snapshot.phase == .idle || snapshot.phase == .connected {
            notificationTasks.removeValue(forKey: id)?.cancel()
            notificationGenerations[id] = nil
            if snapshot.phase == .idle { notificationPolicy.reset(profileID: id) }
            return
        }
        if snapshot.phase == .error || snapshot.phase == .authRequired {
            notificationTasks.removeValue(forKey: id)?.cancel()
            notificationGenerations[id] = nil
        }
        guard settings.showNotifications, let services = systemServices,
              let message = ConnectionNotificationPolicy.message(for: snapshot.phase),
              !snapshot.humanReadableDetail.contains("自动重连已关闭"), notificationTasks[id] == nil else { return }
        let delay = snapshot.phase == .degraded ? degradedNotificationDelaySeconds : 0
        let generation = UUID()
        notificationGenerations[id] = generation
        notificationTasks[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, self.notificationGenerations[id] == generation else { return }
            defer { self.notificationTasks[id] = nil; self.notificationGenerations[id] = nil }
            guard !Task.isCancelled, self.settings.showNotifications,
                  let current = self.snapshots[id], current.phase != .idle && current.phase != .connected,
                  (snapshot.phase != .degraded || current.phase == .degraded) else { return }
            guard self.notificationPolicy.shouldSend(profileID: id, now: Date()) else { return }
            do { try await services.postNotification(profileID: id, body: message) }
            catch { self.logStore.append(raw: "发送连接异常通知失败：\(error.localizedDescription)", level: .warning, profileId: id) }
        }
    }

    func shutdown() {
        notificationTasks.values.forEach { $0.cancel() }
        notificationTasks.removeAll()
        notificationGenerations.removeAll()
        pendingStartupProfiles.removeAll()
        pendingPasswordProfileId = nil
        passwordPromptQueue.removeAll()
        systemServices?.stopObserving()
        tunnel.terminateAllSessions()
    }

    private func persist() {
        document = ProfilesDocument(
            schemaVersion: ProfilesDocument.currentSchemaVersion,
            profiles: profiles,
            currentProfileId: currentProfileId
        )
        do {
            try profileStore.save(document)
        } catch {
            logStore.append(raw: "保存配置失败：\(error.localizedDescription)", level: .error)
        }
    }
}
