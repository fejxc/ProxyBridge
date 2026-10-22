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

    /// 服务器配置生命周期（CRUD / 校验 / ssh config 导入 / 落盘），见 ProfileManager。
    let profileManager: ProfileManager
    let settingsStore: AppSettingsStore
    let tunnel: TunnelService
    let proxyDetector: ProxyDetectorService
    let logStore: LogStore
    /// SSH 密码的安全存储（生产 Keychain；测试内存实现）。
    let trafficStore = TrafficStore()
    let secrets: any PasswordStoring
    /// 主机指纹信任（TOFU）：nil = 功能不可用（测试环境）。
    private let hostKeyTrust: (any HostKeyTrustProviding)?
    /// 更新流（检查 + 提醒 + 应用内安装）：逻辑自治，见 UpdateCoordinator。
    let updates: UpdateCoordinator
    /// 防「空闲休眠」电源断言：nil = 功能不可用。
    private let powerAssertion: (any PowerAssertionControlling)?
    /// 远端端口残留诊断清理：nil = 功能不可用。
    private let remoteJanitor: (any RemoteJanitorProviding)?
    /// 远端端口冲突自愈闭环（诊断/清理卡片），见 ConflictRemediationCoordinator。
    private let conflicts: ConflictRemediationCoordinator

    // MARK: - 冲突清理 facade（实现在 ConflictRemediationCoordinator）

    var portConflict: (profileID: UUID, state: ConflictRemediationCoordinator.UIState)? { conflicts.card }

    var portConflictProfileName: String? {
        portConflict.flatMap { conflict in profiles.first { $0.id == conflict.profileID }?.name }
    }

    /// 用户在卡片上点「重新诊断」。
    func reinspectRemoteResidue() {
        conflicts.reinspect()
    }

    /// 用户确认后：仅清理可清理对象（僵尸 sshd / 自家孤儿 Privoxy），释放成功即自动重连。
    func cleanRemoteResidueAndReconnect() {
        conflicts.cleanAndReconnect()
    }

    /// 用户忽略本次诊断结果。
    func dismissPortConflictCard() {
        conflicts.dismiss()
    }

    // MARK: - 状态

    // MARK: - Profile facade（存储与 CRUD 在 ProfileManager；同名转发保持视图/测试访问路径不变）

    var profiles: [ServerProfile] { profileManager.profiles }
    var currentProfileId: UUID? { profileManager.currentProfileId }
    var editorIsNewDraft: Bool { profileManager.editorIsNewDraft }

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

    // MARK: - 主机指纹引导（P0：首次连接免终端）
    /// 等待用户核对主机指纹的 profile（nil = 无）。
    private(set) var pendingHostKeyProfileId: UUID?
    /// 指纹扫描进度/结果（配合 pendingHostKeyProfileId 展示）。
    enum HostKeyScanState: Equatable {
        case idle
        case scanning
        case fetched([HostKeyRecord])
        case failed(String)
    }
    private(set) var hostKeyScan: HostKeyScanState = .idle

    // MARK: - 更新流 facade（实现在 UpdateCoordinator；同名转发保持视图/测试访问路径不变）

    var updateInfo: UpdateInfo? { updates.info }
    var updateCheckUIState: UpdateCoordinator.CheckUIState { updates.checkUIState }
    var updateInstallState: UpdateCoordinator.InstallUIState { updates.installState }
    var relaunchAfterUpdate: (() -> Void)? {
        get { updates.relaunchAfterUpdate }
        set { updates.relaunchAfterUpdate = newValue }
    }
    static var currentVersion: String { UpdateCoordinator.currentVersion }

    func checkForUpdates(manual: Bool) async {
        await updates.checkForUpdates(manual: manual)
    }

    func openReleasePage() {
        updates.openReleasePage()
    }

    func downloadAndInstallUpdate() {
        updates.downloadAndInstallUpdate()
    }

    // MARK: - 动态→静态回升（P1）
    /// 升回静态的冷却记录（防抖：代理不稳时避免模式反复横跳）。
    private var upgradeAttempts: [UUID: Date] = [:]
    /// 上一次扫描看到的已验证端点（要求连续两次扫描一致才升级）。
    private var lastSeenVerifiedEndpoint: [UUID: String] = [:]
    private static let upgradeRetryCooldown: TimeInterval = 60

    // MARK: - 防休眠/会话时长（P1/P2）
    /// 各 profile 当前连接建立时间（展示会话时长用）。
    private(set) var connectedSince: [UUID: Date] = [:]
    private var keepAwakeFailureLogged = false
    /// 已提示过「未开自动重连」的失败 profile（成功后复位，可再次提示）。
    private var reconnectHintShown: Set<UUID> = []
    /// 各 profile 上次记录「成功健康检查」日志的时间（节流用）。
    private var lastHealthyCheckLogAt: [UUID: Date] = [:]
    private static let healthyCheckLogInterval: TimeInterval = 300

    // MARK: - 系统服务（登录项 / 通知 / 睡眠唤醒）
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
    /// 端点切换尝试的冷却记录（profile → 端点 id + 时间），避免重复扫描反复触发。
    private var retargetAttempts: [UUID: (endpointID: String, at: Date)] = [:]
    /// 上次因本地验证失败触发主动重扫的时间（代理波动场景闭环）。
    private var lastFailureRescanAt: Date?
    /// 上一次观测到的代理出口 IP（节点切换指纹比对）。
    private var lastEgressIP: String?
    /// 上一次观测到的当前网络出口（无本地端口模式指纹比对）。
    private var lastDirectEgressIP: String?
    /// 在线路径特征变化后的最小复测间隔，防止系统路径抖动造成风暴。
    private var lastPathRevalidationAt: Date?
    private static let retargetRetryCooldown: TimeInterval = 20
    private static let failureRescanCooldown: TimeInterval = 30
    private static let pathRevalidationCooldown: TimeInterval = 10
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
        systemServices: (any AppSystemIntegrating)? = nil,
        hostKeyTrust: (any HostKeyTrustProviding)? = nil,
        updateChecker: (any UpdateChecking)? = nil,
        powerAssertion: (any PowerAssertionControlling)? = nil,
        remoteJanitor: (any RemoteJanitorProviding)? = nil,
        updateInstaller: (any UpdateInstalling)? = nil
    ) {
        self.settingsStore = settingsStore
        self.tunnel = tunnel
        self.proxyDetector = proxyDetector
        self.logStore = logStore
        self.secrets = secrets
        self.systemServices = systemServices
        self.hostKeyTrust = hostKeyTrust
        self.profileManager = ProfileManager(profileStore: profileStore, logStore: logStore)
        self.updates = UpdateCoordinator(
            updateChecker: updateChecker,
            updateInstaller: updateInstaller,
            logStore: logStore
        )
        self.conflicts = ConflictRemediationCoordinator(remoteJanitor: remoteJanitor, logStore: logStore)
        self.powerAssertion = powerAssertion
        self.remoteJanitor = remoteJanitor

        // 装配需要引用 self 的闭包（全部存储属性已初始化之后才可捕获 self）。
        // 安装器步骤日志接进应用日志（协议之外的具体实现能力，就地向下转型装配）
        if let dmgInstaller = updateInstaller as? DMGUpdateInstaller {
            dmgInstaller.stepLog = { [weak self] message in
                self?.logStore.append(raw: message, level: .info)
            }
        }
        profileManager.attach(
            snapshot: { [weak self] id in self?.snapshots[id] },
            applySnapshot: { [weak self] snap in self?.snapshots[snap.profileId] = snap },
            updateReconnectPreference: { [weak self] id, reconnectEnabled, rememberPassword in
                self?.tunnel.updateReconnectPreference(profileID: id, enabled: reconnectEnabled, rememberPassword: rememberPassword)
            },
            onProfileAdded: { [weak self] id in self?.snapshots[id] = TunnelSnapshot.idle(id) },
            onProfileRemoving: { [weak self] id in self?.tearDownProfileState(id) }
        )
        conflicts.attach(
            profile: { [weak self] id in self?.profileManager.profile(id: id) },
            storedPassword: { [weak self] id in
                guard let self, let p = self.profileManager.profile(id: id), p.rememberPassword else { return nil }
                return self.secrets.load(for: id)
            },
            reconnect: { [weak self] profile in self?.connect(profile: profile) }
        )
        updates.attach(
            settings: { [weak self] in self?.settings ?? .defaults() },
            postNewVersionNotice: { [weak self] info in self?.postUpdateNotice(info) }
        )
        bootstrap()
    }

    /// 生产装配：本地代理检测与 SSH 隧道均为真实实现
    /// （SCDynamicStore + curl 实测；/usr/bin/ssh 参数数组直启）。
    static func live() -> AppViewModel {
        let sshFactory = FoundationSSHProcessFactory()
        return AppViewModel(
            profileStore: ProfileRepository(),
            settingsStore: AppSettingsStore(),
            tunnel: ManagedTunnelService(underlying: SSHTunnelCoordinator(
                processFactory: sshFactory,
                localProber: CurlProxyProbe(),
                remoteProber: SSHRemoteProbe(factory: sshFactory),
                secrets: KeychainPasswordStore(),
                relayFactory: TCPRelayFactory(),
                httpEntryFactory: HTTPEntryRelayFactory()
            )),
            proxyDetector: LocalProxyDetector(
                provider: SCDynamicStoreProxyProvider(),
                prober: CurlProxyProbe(),
                monitor: SCDynamicStoreChangeMonitor(),
                egressProber: CurlEgressIPProbe(),
                directEgressProber: CurlEgressIPProbe()
            ),
            logStore: LogStore.live(),
            secrets: KeychainPasswordStore(),
            systemServices: AppSystemServices(),
            hostKeyTrust: HostKeyTrustService(),
            updateChecker: GitHubReleaseUpdateChecker(),
            powerAssertion: PowerAssertionService(),
            remoteJanitor: SSHRemoteJanitor(factory: sshFactory),
            updateInstaller: DMGUpdateInstaller()
        )
    }

    private func bootstrap() {
        settings = settingsStore.load()
        L10n.apply(settings.language)
        if settingsStore.lastLoadWasCorrupted {
            logStore.append(raw: "settings.json 无法解析，已回退默认设置（文件保留原样，便于人工排查）", level: .error)
        }

        profileManager.loadFromDisk()
        for p in profileManager.profiles {
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
        systemServices?.onNetworkRestored = { [weak self] in
            self?.handleNetworkRestored()
        }
        systemServices?.onNetworkPathChanged = { [weak self] path in
            self?.handleNetworkPathChanged(path)
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

        // 更新检查：延迟 3 秒启动，不与首连/检测抢资源（只读公开 API，无上行数据）。
        // 启动时代理/网络可能尚未就绪：失败后 60 秒自动重试一次（之后靠网络恢复事件）。
        if settings.checkForUpdates {
            updates.startAutomaticChecks()
        }
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
                self.retargetActiveTunnelsIfEndpointChanged()
                self.upgradeDynamicTunnelsWhenProxyRecovered()
                self.handleEgressIPChange(state.egressIP)
                self.handleDirectEgressIPChange(state.directEgressIP)
            }
        }
    }

    /// U15 动态感知：本地代理端点变化时，活跃静态转发隧道无缝切换到新端点。
    /// 只对「使用中的端点 ≠ 最新解析端点」的 profile 下发；相同端点的重复扫描不触发，
    /// 冷却窗口内的重复尝试被忽略（实测失败的场景由下次检测重试）。
    /// 物理端点 = host + port：混合端口上 HTTP/SOCKS5 探测结论的翻转不构成
    /// 真实端点变化（Relay 是透明字节管道，转发目标没变），不触发切换——
    /// 消除真实日志中观察到的 7897 HTTP↔SOCKS5 反复横跳噪声。
    private func retargetActiveTunnelsIfEndpointChanged() {
        for profile in profiles {
            guard tunnel.isActive(profileID: profile.id),
                  resolvedConnectionMode(profile: profile, snapshot: snapshots[profile.id]) == .staticForward else { continue }
            guard let endpoint = endpointValue(of: EndpointResolver.resolve(profile: profile, detection: detection)) else { continue }
            if let current = connectionEndpoints[profile.id],
               current.host == endpoint.host, current.port == endpoint.port {
                continue // 物理端点未变：仅协议结论翻转，无需切换
            }
            let now = Date()
            if let last = retargetAttempts[profile.id], last.endpointID == endpoint.id,
               now.timeIntervalSince(last.at) < Self.retargetRetryCooldown { continue }
            retargetAttempts[profile.id] = (endpoint.id, now)
            let oldDescription = connectionEndpoints[profile.id]
                .map { "\($0.displayEndpoint)（\($0.protocol.displayName)）" } ?? "未知"
            logStore.append(
                raw: "本地代理端点变化：\(oldDescription) → \(endpoint.displayEndpoint)（\(endpoint.protocol.displayName)）；正在无缝切换活跃隧道",
                level: .info, profileId: profile.id
            )
            tunnel.retargetLocalEndpoint(profileID: profile.id, endpoint: endpoint)
        }
    }

    /// 本地代理验证失败（端口漂移/重启，系统配置通知不一定触发）→ 主动重扫发现新端点，
    /// 与 onStateChange → retargetActiveTunnelsIfEndpointChanged 构成自愈闭环。带冷却防风暴。
    private func scheduleProxyRescanAfterLocalFailure() {
        guard !detection.isScanning else { return }
        let now = Date()
        if let last = lastFailureRescanAt, now.timeIntervalSince(last) < Self.failureRescanCooldown { return }
        lastFailureRescanAt = now
        logStore.append(raw: "本地代理未通过验证：主动重新检测，以发现端口变化", level: .info)
        proxyDetector.detect()
    }

    /// 网络路径恢复（Wi-Fi 重连/VPN 起来）：立即重扫本地代理 + 重建允许自动重连的隧道。
    /// 代理常在联网后才可用——顺带补一次更新检查（此前失败是静默的）。
    private func handleNetworkRestored() {
        logStore.append(raw: "网络路径已恢复：重扫本地代理并重建允许自动重连的隧道", level: .info)
        proxyDetector.detect()
        tunnel.handleNetworkRestoration()
        updates.checkAfterNetworkRestored()
    }

    /// 在线路径特征变化（接口/约束/TUN 等）：只复测，不盲目重建 SSH。
    private func handleNetworkPathChanged(_ path: NetworkPathFingerprint) {
        let now = Date()
        guard now.timeIntervalSince(lastPathRevalidationAt ?? .distantPast) >= Self.pathRevalidationCooldown else { return }
        lastPathRevalidationAt = now
        logStore.append(raw: "网络路径特征变化：重新检测代理并复测活跃连接", level: .info)
        proxyDetector.detect()
        for profile in profiles where tunnel.isActive(profileID: profile.id) {
            tunnel.runHealthCheck(profileID: profile.id)
        }
    }

    /// P1 自动回升：automatic 模式回退到动态 SOCKS5 后，本地代理恢复并连续两次扫描
    /// 验证同一端点时，断开重建以切回静态转发（静态模式有流量统计、走 Clash 规则）。
    /// 密码未记住的密码模式不自动升级（避免反复弹密码框）；每 profile 60s 冷却。
    private func upgradeDynamicTunnelsWhenProxyRecovered() {
        for profile in profiles {
            guard profile.connectionMode == .automatic,
                  tunnel.isActive(profileID: profile.id),
                  resolvedConnectionMode(profile: profile, snapshot: snapshots[profile.id]) == .reverseDynamic,
                  let verified = detection.bestVerifiedEndpoint(preferred: profile.preferredProtocol) else {
                if !detection.candidates.isEmpty {
                    lastSeenVerifiedEndpoint[profile.id] = nil
                }
                continue
            }
            // 连续两次扫描看到同一已验证端点才升级（防瞬时恢复引起模式横跳）
            let seenBefore = lastSeenVerifiedEndpoint[profile.id] == verified.id
            lastSeenVerifiedEndpoint[profile.id] = verified.id
            guard seenBefore else { continue }
            if profile.authMode == .password && !profile.rememberPassword {
                logOncePerCooldown(profileID: profile.id, key: &upgradeHintsShown,
                                   message: "本地代理已恢复，但「\(profile.name)」使用未记住的密码，为避免反复询问不自动切回静态；可手动重连升级")
                continue
            }
            let now = Date()
            if let last = upgradeAttempts[profile.id], now.timeIntervalSince(last) < Self.upgradeRetryCooldown { continue }
            upgradeAttempts[profile.id] = now
            logStore.append(
                raw: "本地代理已恢复验证（\(verified.displayEndpoint)）：把「\(profile.name)」从动态 SOCKS5 切回静态转发，正在重建连接",
                level: .info, profileId: profile.id
            )
            tunnel.disconnectForSystemReason(profileID: profile.id, reason: "本地代理已恢复，切回静态转发")
            connect(profile: profile)
        }
    }

    /// 每 profile 冷却一次的提示（防日志刷屏）。
    private var upgradeHintsShown: Set<UUID> = []
    private func logOncePerCooldown(profileID: UUID, key: inout Set<UUID>, message: String) {
        guard !key.contains(profileID) else { return }
        key.insert(profileID)
        logStore.append(raw: message, level: .info, profileId: profileID)
        Task { @MainActor [weak self, profileID] in
            try? await Task.sleep(nanoseconds: UInt64(Self.upgradeRetryCooldown * 1_000_000_000))
            self?.upgradeHintsShown.remove(profileID)
        }
    }

    // MARK: - 主机指纹引导（P0：首次连接免终端）

    var pendingHostKeyProfileName: String? {
        pendingHostKeyProfileId.flatMap { id in profiles.first { $0.id == id }?.name }
    }

    /// 用户点「获取并核对指纹」：ssh-keyscan 拉取远端公钥与 SHA256 指纹。
    func requestHostKeyScan() {
        guard let id = pendingHostKeyProfileId,
              let profile = profiles.first(where: { $0.id == id }) else { return }
        guard let hostKeyTrust else {
            hostKeyScan = .failed("当前构建未装配指纹扫描服务")
            return
        }
        hostKeyScan = .scanning
        logStore.append(raw: "正在获取「\(profile.name)」的主机指纹（ssh-keyscan \(profile.host):\(profile.sshPort)）", level: .info, profileId: id)
        Task { @MainActor [weak self, hostKeyTrust] in
            let records = await hostKeyTrust.scan(host: profile.host, port: profile.sshPort)
            guard let self, self.pendingHostKeyProfileId == id else { return }
            if records.isEmpty {
                self.hostKeyScan = .failed("未获取到主机公钥：网络不可达、SSH 端口未开放或主机名错误")
                self.logStore.append(raw: "主机指纹获取失败（无返回）", level: .error, profileId: id)
            } else {
                self.hostKeyScan = .fetched(records)
            }
        }
    }

    /// 用户确认指纹无误：写入 known_hosts 并自动重连。
    func confirmHostKeyAndReconnect() {
        guard let id = pendingHostKeyProfileId,
              let profile = profiles.first(where: { $0.id == id }),
              case .fetched(let records) = hostKeyScan else { return }
        guard hostKeyTrust?.trust(records) == true else {
            hostKeyScan = .failed("写入 known_hosts 失败：请检查 ~/.ssh 目录与文件权限")
            return
        }
        logStore.append(
            raw: "已信任「\(profile.name)」的主机指纹（写入 \(records.count) 条公钥），自动重连",
            level: .success, profileId: id
        )
        clearHostKeyPrompt(profileID: id)
        connect(profile: profile)
    }

    /// 用户放弃：保持 authRequired 终态（不自动重试，语义与取消密码输入一致）。
    func dismissHostKeyPrompt() {
        guard let id = pendingHostKeyProfileId else { return }
        logStore.append(raw: "已跳过主机指纹确认；可稍后在终端 ssh 一次或重新连接再试", level: .info, profileId: id)
        clearHostKeyPrompt(profileID: id)
    }

    private func clearHostKeyPrompt(profileID: UUID) {
        if pendingHostKeyProfileId == profileID {
            pendingHostKeyProfileId = nil
            hostKeyScan = .idle
        }
    }

    // MARK: - 更新流（实现见 UpdateCoordinator）

    /// 新版本的系统通知动作：开关与授权由系统服务处理，每版本一次的去重已由协调器完成。
    private func postUpdateNotice(_ info: UpdateInfo) {
        guard settings.showNotifications, let services = systemServices else { return }
        let version = info.latestVersion
        Task { @MainActor in
            try? await services.postUpdateNotification(version: version)
        }
    }

    // MARK: - 防空闲休眠（P1）

    /// 依据「设置开关 + 是否有活跃隧道」持有/释放电源断言。
    /// 断言只防「空闲休眠」：合盖、强制睡眠不受影响（如实告知，不虚标）。
    private func updateKeepAwakeAssertion() {
        let activePhases: Set<TunnelPhase> = [.checking, .connecting, .reconnecting, .connected, .degraded]
        let hasActiveTunnel = profiles.contains {
            snapshots[$0.id]?.sshProcessRunning == true && activePhases.contains(snapshots[$0.id]?.phase ?? .idle)
        }
        if settings.keepAwakeWhileConnected, hasActiveTunnel {
            if powerAssertion?.acquire(reason: "ProxyBridge 活跃 SSH 隧道转发") != true, !keepAwakeFailureLogged {
                keepAwakeFailureLogged = true
                logStore.append(raw: "防止空闲休眠断言创建失败：系统可能仍会休眠", level: .warning)
            }
        } else {
            powerAssertion?.release()
            keepAwakeFailureLogged = false
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
            return StatusPresentation(title: L10n.t("未配置"), detail: L10n.t("打开设置添加第一台服务器"), tone: .gray)
        }
        return TunnelStatusPresentation.overall(for: currentSnapshot)
    }

    var healthTriad: (local: HealthCheckDisplay, ssh: HealthCheckDisplay, remote: HealthCheckDisplay) {
        TunnelStatusPresentation.healthTriad(for: currentSnapshot)
    }

    /// 当前应使用的本地代理端点描述（面板「本地代理」行）。
    var resolvedEndpointDescription: String {
        guard let profile = currentProfile else { return "—" }
        if profile.connectionMode == .reverseDynamic {
            return L10n.t("动态 SOCKS5 · 不需要本地代理端口")
        }
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
            return .busy(L10n.t("处理中…"))
        case .connected, .degraded:
            return .disconnect
        }
    }

    // MARK: - Profile 操作 facade（实现在 ProfileManager）

    func selectProfile(_ id: UUID) {
        profileManager.selectProfile(id)
    }

    /// 新 profile 的编辑初值。不含真实服务器默认值（约束：示例不得内置为默认）。
    func makeNewProfileDraft() -> ServerProfile {
        profileManager.makeNewProfileDraft()
    }

    func requestCreateProfile() {
        profileManager.requestCreateProfile()
    }

    /// 编辑器保存草稿。校验失败的非法配置拒绝保存（U06「拒绝保存」半边）。
    @discardableResult
    func saveDraftProfile(_ profile: ServerProfile) -> Bool {
        profileManager.saveDraftProfile(profile)
    }

    /// F02「端口冲突提示」：同主机同远程监听端口会互相顶掉远端监听。
    func remotePortConflictDescription(for profile: ServerProfile) -> String? {
        profileManager.remotePortConflictDescription(for: profile)
    }

    /// 放弃草稿。
    func discardDraft() {
        profileManager.discardDraft()
    }

    /// 新增或更新。若目标 profile 存在活跃连接，则按规范提示需要重连。
    func upsertProfile(_ profile: ServerProfile) {
        profileManager.upsert(profile)
    }

    /// 删除前的安全检查：活跃连接先断开（由本 App 管理的进程）。
    func deleteProfile(_ id: UUID) {
        profileManager.delete(id)
    }

    /// ProfileManager.delete 回调：清理会话侧状态（隧道、密码、通知、快照、卡片）。
    /// 顺序与拆分前 deleteProfile 的清理序列一致。
    private func tearDownProfileState(_ id: UUID) {
        if tunnel.isActive(profileID: id) {
            tunnel.disconnect(profileID: id)
        }
        secrets.delete(for: id) // 清掉可能记住的密码
        snapshots[id] = nil
        trafficStore.remove(id)
        pendingStartupProfiles.remove(id)
        notificationTasks.removeValue(forKey: id)?.cancel()
        notificationGenerations[id] = nil
        notificationPolicy.reset(profileID: id)
        finishPasswordPrompt(profileID: id)
        clearHostKeyPrompt(profileID: id)
        conflicts.dropIfProfileRemoved(id)
    }

    /// 可导入的 ssh config 条目；文件不存在返回 nil。
    func availableSSHConfigEntries() -> [SSHConfigEntry]? {
        profileManager.availableSSHConfigEntries()
    }

    /// 导入选中的条目为服务器（校验失败或与既有配置重复的跳过）。返回成功导入数。
    @discardableResult
    func importSSHConfigEntries(_ entries: [SSHConfigEntry]) -> Int {
        profileManager.importSSHConfigEntries(entries)
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
        let resolved: EndpointResolver.Resolved
        if profile.connectionMode == .reverseDynamic {
            resolved = .none(reason: "动态 SOCKS5 使用 Mac 网络栈，不需要本地代理端口")
        } else {
            resolved = EndpointResolver.resolve(profile: profile, detection: detection)
        }
        if case .none(let reason) = resolved {
            let level: LogLevel = profile.connectionMode == .automatic ? .info : .warning
            let message = profile.connectionMode == .automatic
                ? "自动模式：\(reason)，将尝试反向动态 SOCKS5。"
                : reason
            logStore.append(raw: message, level: level, profileId: profile.id)
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
        logStore.append(raw: "开始检测本地代理（系统设置 + HTTP_PROXY/HTTPS_PROXY/ALL_PROXY + curl 实测 api.openai.com/v1/models）", level: .info)
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

    func setConnectionMode(_ mode: ConnectionMode) {
        guard var profile = currentProfile, profile.connectionMode != mode else { return }
        profile.connectionMode = mode
        upsertProfile(profile)
        logStore.append(raw: "连接模式切换为「\(mode.displayName)」", level: .info, profileId: profile.id)
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
        L10n.apply(settings.language)
        tunnel.updateRuntimeSettings(settings)
        updateKeepAwakeAssertion()
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

    /// 出口 IP 指纹变化 = 用户切换了节点（或节点自身出口变化）。
    /// 端口与系统设置不变、现有检测无感——此处主动发现并立即重验活跃隧道，
    /// 用户无需任何手动操作即可拿到新节点下的真实结论。
    private func handleEgressIPChange(_ egress: String?) {
        defer { lastEgressIP = egress }
        guard let egress else { return } // 探测失败：如实不动，不猜测
        guard let previous = lastEgressIP else {
            logStore.append(raw: "已观测本地代理出口 IP：\(egress)", level: .info)
            return
        }
        guard previous != egress else { return }
        logStore.append(
            raw: "本地代理出口已变化（\(previous) → \(egress)，可能切换了节点）：立即重新验证远端代理；在途连接可能被代理内核中断，新请求将走新出口",
            level: .info
        )
        for profile in profiles where tunnel.isActive(profileID: profile.id) {
            tunnel.runHealthCheck(profileID: profile.id) // 立即远端重验（协调器 5s 冷却兜底）
        }
    }

    /// 无本地端口模式的出口变化线索：触发复测；nil 保持不确定，不触发修复。
    private func handleDirectEgressIPChange(_ egress: String?) {
        defer { lastDirectEgressIP = egress }
        guard let egress else { return }
        guard let previous = lastDirectEgressIP else {
            logStore.append(raw: "已观测当前网络出口 IP：\(egress)", level: .info)
            return
        }
        guard previous != egress else { return }
        logStore.append(
            raw: "当前网络出口已变化（\(previous) → \(egress)）：立即重新验证远端代理；该指纹不能证明 Clash 命中的节点或规则",
            level: .info
        )
        for profile in profiles where tunnel.isActive(profileID: profile.id) {
            tunnel.runHealthCheck(profileID: profile.id)
        }
    }

    /// 在 Finder 中定位磁盘日志文件（~/Library/Logs/ProxyBridge/app.log）。
    func revealLogFile() {
        guard let url = logStore.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        logStore.append(raw: "已在 Finder 中定位日志文件", level: .info)
    }

    // MARK: - 远端依赖指引（P2：从「如实报障」到「给出下一步」）

    /// 当前 profile 的远端缺失依赖（curl / Privoxy）；nil = 无。
    var remoteToolHint: RemoteCommandTemplate.RemoteTool? {
        guard let profile = currentProfile, tunnel.isActive(profileID: profile.id) else { return nil }
        let snap = snapshots[profile.id]
        if snap?.remoteCurlMissing == true { return .curl }
        return nil
    }

    /// 复制安装指引；安装完成后点「检查连接」重新验证。
    func copyRemoteToolInstallHint() {
        guard let tool = remoteToolHint else { return }
        let text = RemoteCommandTemplate.installHintCommands(component: tool)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logStore.append(raw: "已复制远端 \(tool.displayName) 安装指引；安装后点「检查连接」重新验证", level: .info, profileId: currentProfileId)
    }

    // MARK: - 复制

    /// 远端使用命令（按当前实测/选定协议）。无 profile 或端口非法时返回 nil（防御持久化脏数据触发崩溃）。
    func remoteCommandText() -> String? {
        guard let profile = currentProfile else { return nil }
        let snapshot = snapshots[profile.id]
        if resolvedConnectionMode(profile: profile, snapshot: snapshot) == .reverseDynamic {
            return RemoteCommandTemplate.dynamicClipboardText(
                socksPort: profile.remoteSocksPort,
                httpPort: profile.remoteHTTPPort,
                includeHTTPAdapter: profile.httpAdapterEnabled,
                socksVerified: snapshot?.remoteProbeVerified,
                httpVerified: snapshot?.httpAdapterVerified
            )
        }
        guard (1...65_535).contains(profile.remotePort) else {
            logStore.append(raw: "服务器「\(profile.name)」的远程端口 \(profile.remotePort) 非法，已拒绝生成命令；请修正配置", level: .error, profileId: profile.id)
            return nil
        }
        let activeEndpoint = snapshot?.sshProcessRunning == true
            ? connectionEndpoints[profile.id] : nil
        let endpoint = activeEndpoint ?? endpointValue(of: EndpointResolver.resolve(profile: profile, detection: detection))
        let proto = endpoint?.protocol ?? profile.preferredProtocol
        return RemoteCommandTemplate.clipboardText(
            remotePort: profile.remotePort,
            protocol: proto,
            remoteVerified: snapshot?.remoteProbeVerified
        )
    }

    func remoteSOCKSProbeText() -> String? {
        guard let profile = currentProfile,
              resolvedConnectionMode(profile: profile, snapshot: snapshots[profile.id]) == .reverseDynamic else { return nil }
        var command = RemoteCommandTemplate.socksProbeCommand(remotePort: profile.remoteSocksPort)
        if snapshots[profile.id]?.remoteProbeVerified != true {
            command = command.map { "# SOCKS5 尚未通过真实远端请求验证\n\($0)" }
        }
        return command
    }

    func remoteHTTPCompatibilityText() -> String? {
        guard let profile = currentProfile,
              profile.httpAdapterEnabled,
              resolvedConnectionMode(profile: profile, snapshot: snapshots[profile.id]) == .reverseDynamic else { return nil }
        var commands = RemoteCommandTemplate.httpCompatibilityCommands(remotePort: profile.remoteHTTPPort)
        if snapshots[profile.id]?.httpAdapterVerified != true {
            commands = commands.map { "# HTTP 入口尚未通过 HTTP CONNECT 验证\n\($0)" }
        }
        return commands
    }

    func copyRemoteCommandToPasteboard() {
        guard let text = remoteCommandText() else { return }
        copyToPasteboard(text, logMessage: "已复制远端代理使用命令到剪贴板")
    }

    func copyRemoteSOCKSProbeToPasteboard() {
        guard let text = remoteSOCKSProbeText() else { return }
        copyToPasteboard(text, logMessage: "已复制 SOCKS5 验收命令")
    }

    func copyRemoteHTTPCompatibilityToPasteboard() {
        guard let text = remoteHTTPCompatibilityText() else { return }
        copyToPasteboard(text, logMessage: "已复制 HTTP_PROXY 与 CONNECT 验收命令")
    }

    private func copyToPasteboard(_ text: String, logMessage: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logStore.append(raw: logMessage, level: .info, profileId: currentProfileId)
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

    private func resolvedConnectionMode(profile: ServerProfile, snapshot: TunnelSnapshot?) -> ConnectionMode {
        if let active = snapshot?.effectiveMode, active == .staticForward || active == .reverseDynamic {
            return active
        }
        if profile.connectionMode != .automatic { return profile.connectionMode }
        if case .none = EndpointResolver.resolve(profile: profile, detection: detection) {
            return .reverseDynamic
        }
        return .staticForward
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
        // 活跃会话上报的端点是权威值（含无缝切换后的新端点）：复制命令等展示跟随
        if snap.sshProcessRunning, let active = snap.activeLocalEndpoint {
            connectionEndpoints[snap.profileId] = active
        }
        if snap.phase == .degraded, snap.localProxyVerified == false, snap.sshProcessRunning {
            scheduleProxyRescanAfterLocalFailure()
        }
        // 远端端口绑定冲突 → 自动发起只读诊断（用户确认后才清理）
        if snap.phase == .error, ManagedTunnelService.isRemoteBindConflict(snap.humanReadableDetail) {
            conflicts.scheduleInspection(profileID: snap.profileId)
        }
        // 冲突后恢复连接成功 → 诊断卡撤下（清理中的除外，清理流程自己收尾）
        if snap.phase == .connected {
            conflicts.withdrawIfResolved(profileID: snap.profileId)
        }
        // 主机指纹引导：置位时登记待确认；离开该 profile 的会话即清除
        if snap.hostKeyNeedsTrust {
            if pendingHostKeyProfileId == nil {
                pendingHostKeyProfileId = snap.profileId
                hostKeyScan = .idle
            }
        } else if pendingHostKeyProfileId == snap.profileId, !snap.hostKeyNeedsTrust,
                  snap.phase != .authRequired {
            clearHostKeyPrompt(profileID: snap.profileId)
        }
        // 会话时长（动态模式流量不可用时的诚实展示）
        if snap.sshProcessRunning, [.connected, .degraded].contains(snap.phase) {
            if connectedSince[snap.profileId] == nil { connectedSince[snap.profileId] = Date() }
        } else {
            connectedSince[snap.profileId] = nil
        }
        // 失败终态且未开启自动重连：明确指出可开启（每次失败提示一次，成功后复位）
        if snap.phase == .connected {
            reconnectHintShown.remove(snap.profileId)
        } else if [.error, .authRequired].contains(snap.phase),
                  !tunnel.isActive(profileID: snap.profileId),
                  let profile = profiles.first(where: { $0.id == snap.profileId }),
                  !profile.reconnectEnabled,
                  reconnectHintShown.insert(snap.profileId).inserted {
            logStore.append(
                raw: "「\(profile.name)」连接已失败且未开启自动重连；需要自动恢复请在服务器配置中打开「网络波动时自动恢复 SSH 连接」",
                level: .info, profileId: snap.profileId
            )
        }
        updateKeepAwakeAssertion()
        guard previous?.phase != snap.phase || previous?.humanReadableDetail != snap.humanReadableDetail else { return }
        // 节流：connected 稳定期间的周期性「检查成功」快照（本地/远端检查交替使 detail
        // 反复变化，曾占日志九成体量）——5 分钟内不重复记录；异常快照不受限。
        let isHealthyCheck = snap.phase == .connected
            && snap.humanReadableDetail.contains("完成")
            && !snap.humanReadableDetail.contains("未通过")
        if isHealthyCheck {
            if let last = lastHealthyCheckLogAt[snap.profileId],
               Date().timeIntervalSince(last) < Self.healthyCheckLogInterval {
                lastHealthyCheckLogAt[snap.profileId] = Date() // 顺延窗口，稳定期保持静默
                return
            }
            lastHealthyCheckLogAt[snap.profileId] = Date()
        } else {
            lastHealthyCheckLogAt[snap.profileId] = nil
        }
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
        clearHostKeyPrompt(profileID: pendingHostKeyProfileId ?? UUID())
        connectedSince.removeAll()
        conflicts.reset()
        powerAssertion?.release()
        systemServices?.stopObserving()
        tunnel.terminateAllSessions()
    }
}
