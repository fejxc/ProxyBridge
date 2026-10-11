import Foundation
import AppKit
import Observation

/// 设置窗口的四个分区。
enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case servers, proxy, logs, general
    var id: String { rawValue }
}

/// 应用级 ViewModel：持有全部 UI 状态，桥接服务与持久化。
/// View 层只读状态、调用方法，不包含业务逻辑（阶段 A 要求）。
@MainActor
@Observable
final class AppViewModel {
    // MARK: - 依赖（注入）

    let profileStore: ProfileRepository
    let settingsStore: AppSettingsStore
    let tunnel: TunnelService
    let proxyDetector: ProxyDetectorService
    let logStore: LogStore

    /// 阶段标识：UI 用它显示「演示模式」横幅。阶段 C 完成后移除。
    let isDemoMode = true

    // MARK: - 状态

    private(set) var profiles: [ServerProfile] = []
    private(set) var currentProfileId: UUID?
    private(set) var snapshots: [UUID: TunnelSnapshot] = [:]
    private(set) var detection = ProxyDetectionState()
    private(set) var settings: AppSettings = .defaults()
    var settingsTab: SettingsTab = .servers

    private var document: ProfilesDocument = .empty()

    // MARK: - 初始化

    init(
        profileStore: ProfileRepository,
        settingsStore: AppSettingsStore,
        tunnel: TunnelService,
        proxyDetector: ProxyDetectorService,
        logStore: LogStore
    ) {
        self.profileStore = profileStore
        self.settingsStore = settingsStore
        self.tunnel = tunnel
        self.proxyDetector = proxyDetector
        self.logStore = logStore

        bootstrap()
    }

    /// 阶段 A 的默认装配：Mock 服务 + 默认存储路径。
    static func phaseADefault() -> AppViewModel {
        AppViewModel(
            profileStore: ProfileRepository(),
            settingsStore: AppSettingsStore(),
            tunnel: MockTunnelService(),
            proxyDetector: MockProxyDetector(),
            logStore: LogStore()
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

        wireServices()

        logStore.append(raw: "ProxyBridge 启动（阶段 A：UI 与持久化已实现，SSH 与真实检测为演示）", level: .info)
        if profiles.isEmpty {
            logStore.append(raw: "尚未配置服务器，请打开设置添加", level: .info)
        }
        proxyDetector.detect()
    }

    private func wireServices() {
        tunnel.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .snapshot(let snap):
                self.applySnapshot(snap)
            }
        }
        proxyDetector.onStateChange = { [weak self] state in
            self?.detection = state
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
        persist()
    }

    /// 删除前的安全检查：活跃连接先断开（由本 App 管理的进程）。
    func deleteProfile(_ id: UUID) {
        if tunnel.isActive(profileID: id) {
            tunnel.disconnect(profileID: id)
        }
        let name = profiles.first { $0.id == id }?.name ?? "?"
        profiles.removeAll { $0.id == id }
        snapshots[id] = nil
        if currentProfileId == id {
            currentProfileId = profiles.first?.id
        }
        logStore.append(raw: "已删除服务器「\(name)」", level: .warning, profileId: id)
        persist()
    }

    // MARK: - 连接动作

    func connect() {
        guard let profile = currentProfile else { return }
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
        logStore.append(raw: "请求连接「\(profile.name)」（演示模式：不会启动真实 SSH）", level: .info, profileId: profile.id, isDemoEvent: true)
        tunnel.connect(configuration: config)
    }

    func disconnect() {
        guard let profile = currentProfile else { return }
        logStore.append(raw: "用户手动断开「\(profile.name)」（演示）", level: .info, profileId: profile.id, isDemoEvent: true)
        tunnel.disconnect(profileID: profile.id)
    }

    func runHealthCheck() {
        guard let profile = currentProfile else { return }
        if !tunnel.isActive(profileID: profile.id) && snapshots[profile.id]?.phase == .idle {
            logStore.append(raw: "尚未连接，先连接再检查（演示）", level: .warning, profileId: profile.id, isDemoEvent: true)
            return
        }
        logStore.append(raw: "开始检查连接：本地代理 / SSH 隧道 / 远端代理（演示数据，非真实探测）", level: .info, profileId: profile.id, isDemoEvent: true)
        tunnel.runHealthCheck(profileID: profile.id)
    }

    // MARK: - 代理检测

    func redetectProxy() {
        logStore.append(raw: "开始重新检测本地代理（阶段 A：演示数据，未读取系统设置）", level: .info, isDemoEvent: true)
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
        let proto: ProxyProtocol
        if case .manual(let ep) = EndpointResolver.resolve(profile: profile, detection: detection) {
            proto = ep.protocol
        } else {
            proto = profile.preferredProtocol
        }
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
    }

    // MARK: - 内部

    private func endpointValue(of resolved: EndpointResolver.Resolved) -> LocalProxyEndpoint? {
        switch resolved {
        case .manual(let ep), .auto(let ep): return ep
        case .none: return nil
        }
    }

    private func applySnapshot(_ snap: TunnelSnapshot) {
        let previous = snapshots[snap.profileId]?.phase
        snapshots[snap.profileId] = snap
        guard previous != snap.phase else { return }
        let name = profiles.first { $0.id == snap.profileId }?.name ?? "?"
        let level: LogLevel
        switch snap.phase {
        case .connected: level = .success
        case .degraded, .authRequired, .error: level = .warning
        default: level = .info
        }
        let phrase = TunnelStatusPresentation.overall(for: snap)
        logStore.append(
            raw: "「\(name)」状态：\(phrase.title)（\(phrase.detail)）",
            level: level,
            profileId: snap.profileId,
            isDemoEvent: true
        )
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
