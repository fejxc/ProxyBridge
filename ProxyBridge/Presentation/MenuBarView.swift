import SwiftUI
import AppKit

/// 菜单栏弹出面板（约 368pt 宽，结构对应原型 01）。
@MainActor
struct MenuBarView: View {
    @Environment(AppViewModel.self) private var model
    /// 退出二步确认（MenuBarExtra 面板里系统 confirmationDialog 常无法呈现，
    /// 改为面板内联确认条；8 秒无操作自动复位）。
    @State private var confirmQuit = false
    @State private var confirmQuitResetTask: Task<Void, Never>?

    /// 打开设置并把窗口带到前台（菜单栏应用无 Dock 图标，必须显式激活）。
    private func openSettingsFront(tab: SettingsTab) {
        model.openSettings(tab: tab)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 是否有活跃隧道（退出前二次确认用）。
    private var hasActiveTunnel: Bool {
        model.profiles.contains { model.tunnel.isActive(profileID: $0.id) }
    }

    /// 活跃隧道数量（确认条文案用）。
    private var activeTunnelCount: Int {
        model.profiles.filter { model.tunnel.isActive(profileID: $0.id) }.count
    }

    private func requestQuit() {
        guard hasActiveTunnel else {
            NSApplication.shared.terminate(nil) // 触发 willTerminate → 清理全部子进程
            return
        }
        confirmQuit = true
        confirmQuitResetTask?.cancel()
        confirmQuitResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            confirmQuit = false
        }
    }

    private func cancelQuit() {
        confirmQuitResetTask?.cancel()
        confirmQuit = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if confirmQuit {
                quitConfirmBar
            }
            if let update = model.updateInfo {
                updateBanner(update)
            }
            if model.profiles.isEmpty {
                emptyState
            } else {
                serverCard
                if model.pendingPasswordProfileId != nil {
                    PasswordPromptCard()
                }
                if model.pendingHostKeyProfileId != nil {
                    HostKeyTrustCard()
                }
                checks
                if let tool = model.remoteToolHint {
                    RemoteToolHintCard(tool: tool) {
                        model.runHealthCheck()
                    } onCopy: {
                        model.copyRemoteToolInstallHint()
                    }
                }
                if let profile = model.currentProfile {
                    TrafficStatsView(
                        session: model.trafficStore.session(for: profile.id),
                        connected: model.currentSnapshot.sshProcessRunning &&
                            [.connected, .degraded].contains(model.currentSnapshot.phase),
                        supported: !isDynamicMode,
                        connectedSince: model.connectedSince[profile.id]
                    )
                }
                actions
                links
            }
            footer
        }
        .padding(16)
        .frame(width: 368)
        .background(Palette.background)
        .onDisappear { cancelQuit() }
    }

    /// 退出确认条：面板内联，不依赖系统对话框。
    private var quitConfirmBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("退出将断开 \(activeTunnelCount) 条活跃隧道")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("SSH 进程会被终止，不会遗留。")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            Button {
                cancelQuit()
                NSApplication.shared.terminate(nil)
            } label: {
                Text("确认退出")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(Palette.red)
            Button(L10n.t("取消"), role: .cancel) {
                cancelQuit()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(Palette.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("退出确认")
    }

    /// 新版本横幅：面板顶部醒目入口（替代仅 links 行的小链接）。
    private func updateBanner(_ update: UpdateInfo) -> some View {
        Button {
            model.openReleasePage()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(Palette.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("新版本 ") + "v\(update.latestVersion) " + L10n.t("可用"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("v\(Self.currentVersion) → v\(update.latestVersion)")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(Palette.blue)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新版本提示")
    }

    private static var currentVersion: String { AppViewModel.currentVersion }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Palette.blue.opacity(0.12))
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.blue)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("ProxyBridge")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Text(L10n.t("SSH 反向代理管理"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Button {
                requestQuit()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help(L10n.t("退出 ProxyBridge"))
            .accessibilityLabel(L10n.t("退出 ProxyBridge"))
            Button {
                openSettingsFront(tab: .servers)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help(L10n.t("打开设置"))
            .accessibilityLabel(L10n.t("打开设置"))
        }
    }

    // MARK: 空状态（首次使用引导，UI-SPEC 2.3 的空状态替代）

    private var emptyState: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("尚未配置服务器"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(L10n.t("第一步：在设置中确认本地代理；第二步：添加服务器并填写 SSH 信息。"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    openSettingsFront(tab: .servers)
                } label: {
                    Label(L10n.t("打开设置，添加服务器"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: 服务器卡

    private var serverCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Palette.softFill)
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 16))
                            .foregroundStyle(Palette.muted)
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.currentProfile?.name ?? "—")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        MonoText(text: model.currentProfile?.displayTarget ?? "—", weight: .medium, size: 11)
                            .foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 4)
                    StatusTag(text: model.overallPresentation.title, tone: model.overallPresentation.tone)
                }

                Picker(L10n.t("选择服务器"), selection: Binding(
                    get: { model.currentProfileId ?? UUID() },
                    set: { model.selectProfile($0) }
                )) {
                    ForEach(model.profiles) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.large)
                .accessibilityLabel(L10n.t("选择当前服务器"))

                Divider()

                Text(model.overallPresentation.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(isDynamicMode ? L10n.t("Mac 网络出口") : L10n.t("本地上游 · Mac"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                        MonoText(text: localEndpointDisplay)
                        MiniBadge(text: L10n.t("模式 · ") + connectionModeLabel, tone: .blue)
                        MiniBadge(text: localRouteBadge, tone: isDynamicMode ? .orange : .blue)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.muted.opacity(0.7))
                        .padding(.top, 12)
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(isDynamicMode
                             ? (model.currentProfile?.httpAdapterEnabled == true ? "Linux Codex HTTP" : "Linux SOCKS5")
                             : L10n.t("Linux 远端代理"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                        MonoText(text: remoteEndpointDisplay)
                        MiniBadge(text: L10n.t("仅 127.0.0.1 · TCP"), tone: .green)
                        if isDynamicMode && model.currentProfile?.httpAdapterEnabled == true {
                            MonoText(text: "SOCKS5 \(model.currentProfile?.remoteSocksListenDisplay ?? "—")", size: 10)
                            MiniBadge(text: adapterBadgeText, tone: adapterBadgeTone)
                        }
                    }
                }
            }
        }
    }

    private var localEndpointDisplay: String {
        guard let profile = model.currentProfile else { return "—" }
        if isDynamicMode { return L10n.t("使用 Mac 当前网络栈") }
        if let endpoint = model.currentSnapshot.activeLocalEndpoint {
            return "\(endpoint.displayEndpoint) · \(endpoint.protocol.displayName)"
        }
        switch EndpointResolver.resolve(profile: profile, detection: model.detection) {
        case .manual(let endpoint), .auto(let endpoint):
            return "\(endpoint.displayEndpoint) · \(endpoint.protocol.displayName)"
        case .none where profile.connectionMode == .automatic:
            return L10n.t("未发现入口；自动模式将尝试 SOCKS5")
        case .none:
            return L10n.t("需要可验证的本地上游")
        }
    }

    private var isDynamicMode: Bool {
        if model.currentSnapshot.effectiveMode == .reverseDynamic { return true }
        if model.currentSnapshot.effectiveMode == .staticForward { return false }
        return model.currentProfile?.connectionMode == .reverseDynamic
    }

    private var connectionModeLabel: String {
        if isDynamicMode { return ConnectionMode.reverseDynamic.displayName }
        if model.currentSnapshot.effectiveMode == .staticForward { return ConnectionMode.staticForward.displayName }
        return model.currentProfile?.connectionMode.displayName ?? "—"
    }

    private var localRouteBadge: String {
        if isDynamicMode { return L10n.t("不需要本地代理端口") }
        if model.currentSnapshot.effectiveMode == .staticForward { return L10n.t("本地入口已通过实测") }
        return model.resolvedEndpointDescription
    }

    private var remoteEndpointDisplay: String {
        guard let profile = model.currentProfile else { return "—" }
        if isDynamicMode {
            return profile.httpAdapterEnabled
                ? "HTTP \(profile.remoteHTTPListenDisplay)"
                : "SOCKS5 \(profile.remoteSocksListenDisplay)"
        }
        let endpoint = model.currentSnapshot.activeLocalEndpoint
        return "\(ServerProfile.remoteBindHost):\(profile.remotePort) · \(endpoint?.protocol.displayName ?? profile.preferredProtocol.displayName)"
    }

    private var adapterBadgeText: String {
        let snapshot = model.currentSnapshot
        if snapshot.httpAdapterStatus == .verified { return L10n.t("HTTP CONNECT 已验证") }
        if let detail = snapshot.httpAdapterDetail, !detail.isEmpty { return detail }
        return L10n.t("HTTP 入口待验证")
    }

    private var adapterBadgeTone: StatusTone {
        switch model.currentSnapshot.httpAdapterStatus {
        case .verified: return .green
        case .notInstalled, .portConflict, .unavailable: return .orange
        default: return .gray
        }
    }

    // MARK: 三层健康

    private var checks: some View {
        let triad = model.healthTriad
        return VStack(spacing: 0) {
            HealthCheckRow(title: isDynamicMode ? L10n.t("Mac 网络出口") : L10n.t("本地代理"), display: triad.local, detail: localDetail(for: triad.local))
            separator
            HealthCheckRow(title: L10n.t("SSH 隧道"), display: triad.ssh, detail: sshDetail(for: triad.ssh))
            separator
            HealthCheckRow(title: isDynamicMode ? L10n.t("远端 SOCKS5") : L10n.t("远端代理"), display: triad.remote, detail: remoteDetail(for: triad.remote))
            if isDynamicMode && model.currentProfile?.httpAdapterEnabled == true {
                separator
                HealthCheckRow(title: L10n.t("HTTP 兼容入口"), display: httpAdapterDisplay, detail: httpAdapterDetail)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            model.openSettings(tab: .logs)
        }
        .help(L10n.t("点击查看日志定位原因"))
    }

    private var separator: some View {
        Rectangle()
            .fill(Palette.border.opacity(0.6))
            .frame(height: 1)
    }

    private func localDetail(for display: HealthCheckDisplay) -> String {
        if isDynamicMode {
            switch display {
            case .ok: return L10n.t("经远端 SOCKS5 请求验证 Mac 当前网络出站；Clash 节点尚未确认")
            case .unknown: return L10n.t("尚未通过远端请求验证 Mac 出站")
            case .failed: return L10n.t("经 SSH 反向 SOCKS5 的公网请求失败")
            }
        }
        switch display {
        case .ok: return L10n.t("本地代理已通过协议验证")
        case .unknown: return L10n.t("尚未验证本地代理可用性")
        case .failed: return L10n.t("本地代理验证失败：请确认代理已启动或改用手动配置")
        }
    }

    private func sshDetail(for display: HealthCheckDisplay) -> String {
        switch display {
        case .ok:
            let base = "隧道运行中"
            return base
        case .unknown: return L10n.t("正在建立 SSH 连接…")
        case .failed: return model.currentSnapshot.phase == .authRequired
            ? L10n.t("需要核对服务器指纹或 SSH 身份验证")
            : L10n.t("SSH 未连接")
        }
    }

    private func remoteDetail(for display: HealthCheckDisplay) -> String {
        switch display {
        case .ok: return isDynamicMode ? L10n.t("Linux SOCKS5 已通过远端 HTTPS 请求验证") : L10n.t("远端代理端到端验证通过")
        case .unknown: return isDynamicMode ? L10n.t("Linux SOCKS5 尚未验证") : L10n.t("远端代理未验证（未验证 ≠ 可用）")
        case .failed: return L10n.t("远端验证失败，请查看日志定位原因")
        }
    }

    private var httpAdapterDisplay: HealthCheckDisplay {
        if model.currentSnapshot.phase == .idle { return .unknown }
        switch model.currentSnapshot.httpAdapterStatus {
        case .verified: return .ok
        case .notInstalled, .portConflict, .unavailable, .stopped: return .failed
        case .notRequested, .checking, .starting, .running, .stopping: return .unknown
        }
    }

    private var httpAdapterDetail: String {
        model.currentSnapshot.httpAdapterDetail ?? L10n.t("等待 SOCKS5 验活后检查 Privoxy 与 HTTP CONNECT")
    }

    // MARK: 操作

    private var actions: some View {
        HStack(spacing: 8) {
            primaryButton
            Button {
                model.runHealthCheck()
            } label: {
                Label(L10n.t("检查连接"), systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .accessibilityHint("只重新验证，不修改任何配置")
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.primaryAction {
        case .connect:
            Button {
                model.connect()
            } label: {
                Label(L10n.t("连接服务器"), systemImage: "arrow.up.forward")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        case .disconnect:
            Button(role: .destructive) {
                model.disconnect()
            } label: {
                Label(L10n.t("断开连接"), systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(Palette.red)
        case .busy(let text):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(text).font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .controlSize(.large)
        }
    }

    private var links: some View {
        HStack {
            Menu {
                Button(L10n.t("完整环境变量示例")) { model.copyRemoteCommandToPasteboard() }
                if model.remoteSOCKSProbeText() != nil {
                    Button(L10n.t("SOCKS5 验收 curl")) { model.copyRemoteSOCKSProbeToPasteboard() }
                }
                if model.remoteHTTPCompatibilityText() != nil {
                    Button(L10n.t("HTTP_PROXY + CONNECT 验收")) { model.copyRemoteHTTPCompatibilityToPasteboard() }
                }
            } label: {
                Label(L10n.t("复制 Linux 命令"), systemImage: "doc.on.doc")
                    .font(.system(size: 11.5))
            }
            .menuStyle(.borderlessButton)
            .help(L10n.t("复制 Linux SOCKS5 或 HTTP_PROXY 验收命令；不修改服务器配置"))
            Spacer(minLength: 0)
            if let update = model.updateInfo {
                Button {
                    model.openReleasePage()
                } label: {
                    Label(L10n.t("新版本 ") + "v\(update.latestVersion)", systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Palette.blue)
                }
                .buttonStyle(.link)
                .help(L10n.t("打开发布页下载新版本"))
            }
            Button {
                openSettingsFront(tab: .logs)
            } label: {
                Label(L10n.t("查看日志"), systemImage: "list.bullet.rectangle")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.link)
        }
    }

    private var footer: some View {
        Text(L10n.t("产品重点：随时知道本地代理、SSH 隧道、远端代理各自是否正常，而不是只看到「SSH 已连接」。"))
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.muted.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 小徽标（原型 mini-qual）。
@MainActor
struct MiniBadge: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Palette.tone(tone))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Palette.tone(tone).opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
