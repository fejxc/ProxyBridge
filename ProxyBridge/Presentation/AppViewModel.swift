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
    /// 主机指纹信任（TOFU）：nil = 功能不可用（测试环境）。
    private let hostKeyTrust: (any HostKeyTrustProviding)?
    /// 更新检查：nil = 功能不可用。
    private let updateChecker: (any UpdateChecking)?
    /// 防「空闲休眠」电源断言：nil = 功能不可用。
    private let powerAssertion: (any PowerAssertionControlling)?
    /// 远端端口残留诊断清理：nil = 功能不可用。
    private let remoteJanitor: (any RemoteJanitorProviding)?

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

    // MARK: - 更新检查（P0）
    /// 发现的新版本（nil = 无提醒）。
    private(set) var updateInfo: UpdateInfo?
    /// 手动检查的界面反馈（自动检查保持静默语义，只在成功发现时提示）。
    enum UpdateCheckUIState: Equatable {
        case idle
        case checking
        case failed(String)
    }
    private(set) var updateCheckUIState: UpdateCheckUIState = .idle
    /// 已通知过的版本（每版本只发一次系统通知）。
    private var updateNotifiedVersion: String?

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

    // MARK: - 远端残留诊断清理（端口冲突自愈闭环）
    /// 端口冲突卡状态（nil = 无卡）。
    enum PortConflictUIState: Equatable {
        case inspecting
        case unavailable(String)
        case report([RemotePortHolding])
        case cleaning
    }
    private(set) var portConflict: (profileID: UUID, state: PortConflictUIState)?
    private var portConflictInspectedAt: [UUID: Date] = [:]
    private static let portConflictInspectCooldown: TimeInterval = 60

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
    /// 端点切换尝试的冷却记录（profile → 端点 id + 时间），避免重复扫描反复触发。
    private var retargetAttempts: [UUID: (endpointID: String, at: Date)] = [:]
    /// 上次因本地验证失败触发主动重扫的时间（代理波动场景闭环）。
    private var lastFailureRescanAt: Date?
    private static let retargetRetryCooldown: TimeInterval = 20
    private static let failureRescanCooldown: TimeInterval = 30
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
        remoteJanitor: (any RemoteJanitorProviding)? = nil
    ) {
        self.profileStore = profileStore
        self.settingsStore = settingsStore
        self.tunnel = tunnel
        self.proxyDetector = proxyDetector
        self.logStore = logStore
        self.secrets = secrets
        self.systemServices = systemServices
        self.hostKeyTrust = hostKeyTrust
        self.updateChecker = updateChecker
        self.powerAssertion = powerAssertion
        self.remoteJanitor = remoteJanitor

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
                httpAdapterManager: SSHRemoteHTTPAdapterManager(factory: sshFactory)
            )),
            proxyDetector: LocalProxyDetector(
                provider: SCDynamicStoreProxyProvider(),
                prober: CurlProxyProbe(),
                monitor: SCDynamicStoreChangeMonitor()
            ),
            logStore: LogStore.live(),
            secrets: KeychainPasswordStore(),
            systemServices: AppSystemServices(),
            hostKeyTrust: HostKeyTrustService(),
            updateChecker: GitHubReleaseUpdateChecker(),
            powerAssertion: PowerAssertionService(),
            remoteJanitor: SSHRemoteJanitor(factory: sshFactory)
        )
    }

    private func bootstrap() {
        settings = settingsStore.load()
        L10n.apply(settings.language)
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
        systemServices?.onNetworkRestored = { [weak self] in
            self?.handleNetworkRestored()
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
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.settings.checkForUpdates else { return }
                await self.checkForUpdates(manual: false)
                guard self.updateInfo == nil else { return }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard self.settings.checkForUpdates, self.updateInfo == nil else { return }
                await self.checkForUpdates(manual: false)
            }
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
            }
        }
    }

    /// U15 动态感知：本地代理端点变化时，活跃静态转发隧道无缝切换到新端点。
    /// 只对「使用中的端点 ≠ 最新解析端点」的 profile 下发；相同端点的重复扫描不触发，
    /// 冷却窗口内的重复尝试被忽略（实测失败的场景由下次检测重试）。
    private func retargetActiveTunnelsIfEndpointChanged() {
        for profile in profiles {
            guard tunnel.isActive(profileID: profile.id),
                  resolvedConnectionMode(profile: profile, snapshot: snapshots[profile.id]) == .staticForward else { continue }
            guard let endpoint = endpointValue(of: EndpointResolver.resolve(profile: profile, detection: detection)),
                  endpoint.id != connectionEndpoints[profile.id]?.id else { continue }
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
        if settings.checkForUpdates, updateInfo == nil {
            Task { @MainActor [weak self] in await self?.checkForUpdates(manual: false) }
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

    // MARK: - 更新检查（P0）

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// 检查新版本。manual = true 时无论成败都给出界面与日志反馈（设置页按钮触发）。
    func checkForUpdates(manual: Bool) async {
        guard let updateChecker else {
            if manual {
                updateCheckUIState = .failed("当前构建未装配更新检查服务")
                logStore.append(raw: "当前构建未装配更新检查服务", level: .warning)
            }
            return
        }
        if manual { updateCheckUIState = .checking }
        guard let info = await updateChecker.latestRelease() else {
            if manual {
                let reason = "网络不可用或 GitHub 无法访问（需要代理时请先连接本地代理）"
                updateCheckUIState = .failed(reason)
                logStore.append(raw: "检查更新失败：\(reason)", level: .warning)
            }
            return
        }
        if Version.isNewer(candidate: info.latestVersion, current: Self.currentVersion) {
            let isNewVersion = updateInfo?.latestVersion != info.latestVersion
            updateInfo = info
            updateCheckUIState = .idle
            if isNewVersion {
                logStore.append(raw: "发现新版本 v\(info.latestVersion)（当前 v\(Self.currentVersion)）：菜单栏面板与设置页可前往下载", level: .info)
                notifyUpdateOnce(info)
            }
        } else if manual {
            updateCheckUIState = .idle
            logStore.append(raw: "已是最新版本（v\(Self.currentVersion)）", level: .success)
        }
    }

    /// 每个版本只发一次系统通知（授权被拒/无授权时静默，界面横幅仍在）。
    private func notifyUpdateOnce(_ info: UpdateInfo) {
        guard updateNotifiedVersion != info.latestVersion else { return }
        updateNotifiedVersion = info.latestVersion
        guard settings.showNotifications, let services = systemServices else { return }
        let version = info.latestVersion
        Task { @MainActor in
            try? await services.postUpdateNotification(version: version)
        }
    }

    /// 打开发布页（有新版本时直达该版本页面）。
    func openReleasePage() {
        let url = updateInfo?.releaseURL ?? URL(string: "https://github.com/fejxc/ProxyBridge/releases")
        guard let url else { return }
        NSWorkspace.shared.open(url)
        logStore.append(raw: "已打开发布页\(updateInfo.map { "（v\($0.latestVersion)）" } ?? "")", level: .info)
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
        func ports(_ profile: ServerProfile) -> Set<Int> {
            switch profile.connectionMode {
            case .automatic:
                var result: Set<Int> = [profile.remotePort, profile.remoteSocksPort]
                if profile.httpAdapterEnabled { result.insert(profile.remoteHTTPPort) }
                return result
            case .staticForward:
                return [profile.remotePort]
            case .reverseDynamic:
                var result: Set<Int> = [profile.remoteSocksPort]
                if profile.httpAdapterEnabled { result.insert(profile.remoteHTTPPort) }
                return result
            }
        }
        let requestedPorts = ports(profile)
        let conflicts = profiles.filter {
            $0.id != profile.id && $0.host == profile.host && !ports($0).isDisjoint(with: requestedPorts)
        }
        guard !conflicts.isEmpty else { return nil }
        let overlappingPorts = Set(conflicts.flatMap { ports($0).intersection(requestedPorts) })
        let portsText = overlappingPorts.sorted().map(String.init).joined(separator: "、")
        return "「\(profile.name)」与 \(conflicts.map(\.name).joined(separator: "、")) 在同一 SSH 主机上占用重叠的远程端口（\(portsText)），同时连接会互相失败"
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
                || old.remoteSocksPort != profile.remoteSocksPort
                || old.remoteHTTPPort != profile.remoteHTTPPort
                || old.connectionMode != profile.connectionMode
                || old.httpAdapterEnabled != profile.httpAdapterEnabled
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
        clearHostKeyPrompt(profileID: id)
        if portConflict?.profileID == id { portConflict = nil }
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

    /// 在 Finder 中定位磁盘日志文件（~/Library/Logs/ProxyBridge/app.log）。
    func revealLogFile() {
        guard let url = logStore.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        logStore.append(raw: "已在 Finder 中定位日志文件", level: .info)
    }

    // MARK: - 远端残留诊断清理（端口冲突自愈闭环）

    var portConflictProfileName: String? {
        portConflict.flatMap { conflict in profiles.first { $0.id == conflict.profileID }?.name }
    }

    /// 冲突出现时自动只读诊断（带冷却）：识别占用者，可清对象（同用户僵尸 sshd、
    /// 自家孤儿 Privoxy）呈现给用户确认。别人的进程只展示，不提供清理。
    private func scheduleRemoteResidueInspection(profileID: UUID) {
        guard remoteJanitor != nil,
              let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard portConflict == nil else { return } // 已有卡片在展示，不重复诊断
        let now = Date()
        if let last = portConflictInspectedAt[profileID],
           now.timeIntervalSince(last) < Self.portConflictInspectCooldown { return }
        portConflictInspectedAt[profileID] = now
        portConflict = (profileID, .inspecting)
        logStore.append(raw: "检测到远端端口冲突：正在经 SSH 诊断「\(profile.name)」的端口占用", level: .info, profileId: profileID)
        runRemoteInspection(profile: profile, profileID: profileID)
    }

    /// 用户在卡片上点「重新诊断」。
    func reinspectRemoteResidue() {
        guard let id = portConflict?.profileID,
              let profile = profiles.first(where: { $0.id == id }) else { return }
        portConflict = (id, .inspecting)
        runRemoteInspection(profile: profile, profileID: id)
    }

    private func runRemoteInspection(profile: ServerProfile, profileID: UUID) {
        guard let janitor = remoteJanitor else { return }
        var ports = [profile.remotePort, profile.remoteSocksPort]
        if profile.httpAdapterEnabled { ports.append(profile.remoteHTTPPort) }
        let password = profile.rememberPassword ? secrets.load(for: profileID) : nil
        Task { @MainActor [weak self] in
            let holdings = await janitor.inspect(profile: profile, ports: ports, password: password)
            guard let self, self.portConflict?.profileID == profileID else { return }
            guard let holdings else {
                let hint = profile.authMode == .password && password == nil
                    ? "（密码模式且未记住密码，无法自动登录诊断）" : "（SSH 不可达或超时）"
                self.portConflict = (profileID, .unavailable("无法自动诊断\(hint)"))
                return
            }
            if holdings.isEmpty {
                // 冲突已自愈（旧 sshd 已释放）：撤卡，常规重试会自行接上
                self.portConflict = nil
                self.logStore.append(raw: "远端端口诊断：占用已消失（自愈），继续常规重试", level: .info, profileId: profileID)
            } else {
                self.portConflict = (profileID, .report(holdings))
            }
        }
    }

    /// 用户确认后：仅清理 kind.isCleanable 的对象（僵尸 sshd / 自家孤儿 Privoxy），
    /// 释放成功即自动重连。
    func cleanRemoteResidueAndReconnect() {
        guard let (profileID, state) = portConflict, case .report(let holdings) = state,
              let profile = profiles.first(where: { $0.id == profileID }),
              let janitor = remoteJanitor else { return }
        let targets = holdings.filter { $0.kind.isCleanable }
        guard !targets.isEmpty else { return }
        portConflict = (profileID, .cleaning)
        let summary = targets.map { "\($0.port)→PID \($0.pid)（\($0.comm)）" }.joined(separator: "、")
        logStore.append(raw: "用户确认清理远端残留：\(summary)", level: .warning, profileId: profileID)
        let password = profile.rememberPassword ? secrets.load(for: profileID) : nil
        Task { @MainActor [weak self] in
            let outcome = await janitor.clean(profile: profile, targets: targets, password: password)
            guard let self else { return }
            self.portConflict = nil
            guard let outcome else {
                self.logStore.append(raw: "远端清理执行失败（SSH 不可达）", level: .error, profileId: profileID)
                return
            }
            if outcome.allFreed {
                self.logStore.append(raw: "远端残留已清理（释放端口 \(outcome.freedPorts.map(String.init).joined(separator: "、"))），自动重连", level: .success, profileId: profileID)
                self.connect(profile: profile)
            } else {
                self.logStore.append(raw: "远端清理完成但端口 \(outcome.stillHeldPorts.map(String.init).joined(separator: "、")) 仍被占用：可能是他人进程或需要更强信号，请更换端口或联系管理员", level: .warning, profileId: profileID)
            }
        }
    }

    /// 用户忽略本次诊断结果。
    func dismissPortConflictCard() {
        portConflict = nil
    }

    // MARK: - ~/.ssh/config 导入（P2）

    /// 可导入的 ssh config 条目；文件不存在返回 nil。
    func availableSSHConfigEntries() -> [SSHConfigEntry]? {
        SSHConfigParser.loadDefaultConfig()
    }

    /// 导入选中的条目为服务器（校验失败或与既有配置重复的跳过）。返回成功导入数。
    @discardableResult
    func importSSHConfigEntries(_ entries: [SSHConfigEntry]) -> Int {
        var imported = 0
        for entry in entries {
            var profile = ServerProfile(
                name: entry.alias,
                host: entry.hostName ?? entry.alias,
                sshPort: entry.port ?? 22,
                username: entry.user ?? "",
                remotePort: 7890
            )
            if let identity = entry.identityFile {
                profile.authMode = .identityFile
                profile.identityFilePath = identity
            }
            guard ServerProfileRule.validate(profile).isValid else { continue }
            guard !profiles.contains(where: {
                $0.host == profile.host && $0.sshPort == profile.sshPort && $0.username == profile.username
            }) else { continue }
            upsertProfile(profile)
            imported += 1
        }
        if imported > 0 {
            logStore.append(raw: "从 ~/.ssh/config 导入 \(imported) 台服务器（仅 HostName/Port/User/IdentityFile，不含其他指令）", level: .success)
        }
        return imported
    }

    // MARK: - 远端依赖指引（P2：从「如实报障」到「给出下一步」）

    /// 当前 profile 的远端缺失依赖（curl / Privoxy）；nil = 无。
    var remoteToolHint: RemoteCommandTemplate.RemoteTool? {
        guard let profile = currentProfile, tunnel.isActive(profileID: profile.id) else { return nil }
        let snap = snapshots[profile.id]
        if snap?.remoteCurlMissing == true { return .curl }
        if snap?.httpAdapterStatus == .notInstalled { return .privoxy }
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
        // 端口绑定冲突 / Privoxy 端口被占 → 自动发起只读诊断（用户确认后才清理）
        if snap.phase == .error, ManagedTunnelService.isRemoteBindConflict(snap.humanReadableDetail)
            || snap.httpAdapterStatus == .portConflict {
            scheduleRemoteResidueInspection(profileID: snap.profileId)
        }
        // 冲突后恢复连接成功 → 诊断卡撤下（清理中的除外，清理流程自己收尾）
        if snap.phase == .connected, portConflict?.profileID == snap.profileId,
           portConflict?.state != .cleaning {
            portConflict = nil
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
        portConflict = nil
        powerAssertion?.release()
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
