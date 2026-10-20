import Foundation
import AppKit

/// 应用内更新流：启动检查 → 提醒（横幅 + 每版本一次系统通知）→ 下载 → 校验 → 安装 → 重启。
/// 从 AppViewModel 拆出的自治协调器：持有自己的状态与流程；
/// AppViewModel 以同名 facade 转发，视图与测试的访问路径保持不变。
///
/// 校验链不可用（无 DMG 资产 / 拿不到官方校验值 / 校验不通过）时绝不自动安装——
/// 如实报告并保留浏览器下载路径。
@MainActor
@Observable
final class UpdateCoordinator {
    // MARK: - 依赖（注入）

    private let updateChecker: (any UpdateChecking)?
    private let updateInstaller: (any UpdateInstalling)?
    private let logStore: LogStore
    /// 设置实时读取（值语义：每次判断重新求值，与拆分前读 ViewModel.settings 等价）。
    private var settings: () -> AppSettings = { .defaults() }
    /// 新版本的系统通知动作（由 ViewModel 装配：内部处理通知开关与授权）。
    private var postNewVersionNotice: (UpdateInfo) -> Void = { _ in }

    init(
        updateChecker: (any UpdateChecking)?,
        updateInstaller: (any UpdateInstalling)?,
        logStore: LogStore
    ) {
        self.updateChecker = updateChecker
        self.updateInstaller = updateInstaller
        self.logStore = logStore
    }

    /// 装配需要引用宿主 ViewModel 的闭包（init 阶段 self 尚不可捕获，故两段式）。
    /// 必须在首次触发任何流程前调用（AppViewModel 于 init 内装配）。
    func attach(
        settings: @escaping () -> AppSettings,
        postNewVersionNotice: @escaping (UpdateInfo) -> Void
    ) {
        self.settings = settings
        self.postNewVersionNotice = postNewVersionNotice
    }

    // MARK: - 状态

    /// 发现的新版本（nil = 无提醒）。
    private(set) var info: UpdateInfo?
    /// 手动检查的界面反馈（自动检查保持静默语义，只在成功发现时提示）。
    enum CheckUIState: Equatable {
        case idle
        case checking
        case failed(String)
    }
    private(set) var checkUIState: CheckUIState = .idle
    /// 已通知过的版本（每版本只发一次系统通知）。
    private var notifiedVersion: String?
    /// 应用内安装状态（下载 → 校验 → 安装；校验不可用绝不自动安装）。
    enum InstallUIState: Equatable {
        case idle
        case downloading(Double)
        case verifying
        case installing
        case failed(String)
    }
    private(set) var installState: InstallUIState = .idle
    /// 更新安装完成后的重启入口（由 AppDelegate 注入，经 terminate 流程避免单实例锁竞态）。
    var relaunchAfterUpdate: (() -> Void)?

    // MARK: - 检查

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// 检查新版本。manual = true 时无论成败都给出界面与日志反馈（设置页按钮触发）。
    func checkForUpdates(manual: Bool) async {
        guard let updateChecker else {
            if manual {
                checkUIState = .failed("当前构建未装配更新检查服务")
                logStore.append(raw: "当前构建未装配更新检查服务", level: .warning)
            }
            return
        }
        if manual { checkUIState = .checking }
        guard let info = await updateChecker.latestRelease() else {
            if manual {
                let reason = "网络不可用或 GitHub 无法访问（需要代理时请先连接本地代理）"
                checkUIState = .failed(reason)
                logStore.append(raw: "检查更新失败：\(reason)", level: .warning)
            }
            return
        }
        if Version.isNewer(candidate: info.latestVersion, current: Self.currentVersion) {
            let isNewVersion = self.info?.latestVersion != info.latestVersion
            self.info = info
            checkUIState = .idle
            if isNewVersion {
                logStore.append(raw: "发现新版本 v\(info.latestVersion)（当前 v\(Self.currentVersion)）：菜单栏面板与设置页可前往下载", level: .info)
                notifyUpdateOnce(info)
            }
        } else if manual {
            checkUIState = .idle
            logStore.append(raw: "已是最新版本（v\(Self.currentVersion)）", level: .success)
        }
    }

    /// 启动检查：延迟 3 秒，不与首连/检测抢资源（只读公开 API，无上行数据）。
    /// 启动时代理/网络可能尚未就绪：失败后 60 秒自动重试一次（之后靠网络恢复事件）。
    func startAutomaticChecks() {
        guard settings().checkForUpdates else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.settings().checkForUpdates else { return }
            await self.checkForUpdates(manual: false)
            guard self.info == nil else { return }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard self.settings().checkForUpdates, self.info == nil else { return }
            await self.checkForUpdates(manual: false)
        }
    }

    /// 网络路径恢复后补查一次（此前失败的检查是静默的）。
    func checkAfterNetworkRestored() {
        guard settings().checkForUpdates, info == nil else { return }
        Task { @MainActor [weak self] in await self?.checkForUpdates(manual: false) }
    }

    /// 每个版本只发一次系统通知（授权被拒/无授权时静默，界面横幅仍在）。
    private func notifyUpdateOnce(_ info: UpdateInfo) {
        guard notifiedVersion != info.latestVersion else { return }
        notifiedVersion = info.latestVersion
        postNewVersionNotice(info)
    }

    /// 打开发布页（有新版本时直达该版本页面）。
    func openReleasePage() {
        let url = info?.releaseURL ?? URL(string: "https://github.com/fejxc/ProxyBridge/releases")
        guard let url else { return }
        NSWorkspace.shared.open(url)
        logStore.append(raw: "已打开发布页\(info.map { "（v\($0.latestVersion)）" } ?? "")", level: .info)
    }

    // MARK: - 应用内安装（下载 → 校验 → 替换 → 重启）

    /// 下载并安装新版本。校验链不可用（无 DMG 资产 / 拿不到官方校验值 / 校验不通过）
    /// 时绝不自动安装——如实报告并保留浏览器下载路径。
    func downloadAndInstallUpdate() {
        guard let info else { return }
        switch installState {
        case .downloading, .verifying, .installing:
            return // 进行中：幂等忽略
        case .idle, .failed:
            break
        }
        guard let installer = updateInstaller else {
            logStore.append(raw: "当前构建未装配应用内安装器，已打开发布页", level: .info)
            openReleasePage()
            return
        }
        guard let dmgURL = info.dmgURL, let shaURL = info.sha256URL else {
            logStore.append(raw: "本版本发布页缺少 DMG 或校验资产，自动安装不可用；已打开发布页", level: .warning)
            openReleasePage()
            return
        }
        installState = .downloading(0)
        logStore.append(raw: "开始下载 v\(info.latestVersion) 更新包（官方通用 DMG）", level: .info)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let local = await installer.download(url: dmgURL) { [weak self] value in
                Task { @MainActor [weak self] in self?.installState = .downloading(value) }
            }
            guard let local else {
                self.finishInstall(.failed("下载失败：网络不可用或 GitHub 无法访问（需要代理时请先连接本地代理）"))
                return
            }
            guard let expected = await installer.fetchExpectedSHA256(url: shaURL) else {
                self.finishInstall(.failed("无法获取官方 SHA-256 校验值，已取消自动安装（安全优先）"))
                return
            }
            self.installState = .verifying
            guard installer.verify(file: local, expectedHex: expected) else {
                try? FileManager.default.removeItem(at: local)
                self.finishInstall(.failed("SHA-256 校验不通过，已取消安装；请从发布页手动下载"))
                return
            }
            self.installState = .installing
            if installer.installAndRelaunch(dmg: local, expectedVersion: info.latestVersion) {
                try? FileManager.default.removeItem(at: local)
                if Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
                    self.logStore.append(raw: "v\(info.latestVersion) 安装完成，正在重启应用", level: .success)
                    self.relaunchAfterUpdate?()
                } else {
                    self.logStore.append(raw: "v\(info.latestVersion) 已挂载安装卷（当前非 /Applications 运行，请手动拖入）", level: .info)
                    self.installState = .idle
                }
            } else {
                self.finishInstall(.failed("安装失败：无法挂载 DMG 或替换 /Applications 中的应用（应用可能正被占用）"))
            }
        }
    }

    private func finishInstall(_ state: InstallUIState) {
        installState = state
        if case .failed(let reason) = state {
            logStore.append(raw: "更新安装未完成：\(reason)", level: .warning)
        }
    }
}
