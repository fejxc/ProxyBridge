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
    /// 自愈轨迹默认只占一行；展开后才显示状态迁移和原因，减少面板噪声。
    @State private var showRecoveryTrace = false

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
                if model.portConflict != nil {
                    RemotePortConflictCard()
                }
                checks
                recoveryTraceCard
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
        .background(.regularMaterial)
        .onDisappear { cancelQuit() }
    }

    /// 退出确认条：面板内联，不依赖系统对话框。
    private var quitConfirmBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L10n.t("退出将断开 %d 条活跃隧道"), activeTunnelCount))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(L10n.t("SSH 进程会被终止，不会遗留。"))
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            Button {
                cancelQuit()
                NSApplication.shared.terminate(nil)
            } label: {
                Text(L10n.t("确认退出"))
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
        .background(Palette.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("退出确认"))
    }

    /// 新版本横幅：面板顶部醒目入口；支持应用内下载安装（含进度与失败原因）。
    private func updateBanner(_ update: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.openReleasePage()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(Palette.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("新版本 ") + "v\(update.latestVersion) " + L10n.t("可用"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                        Text("v\(Self.currentVersion) → v\(update.latestVersion)")
                            .font(.footnote)
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
            .accessibilityLabel(L10n.t("新版本提示"))

            switch model.updateInstallState {
            case .idle:
                if model.updateInfo?.dmgURL != nil {
                    Button {
                        model.downloadAndInstallUpdate()
                    } label: {
                        Label(L10n.t("自动更新（下载 · 校验 · 安装）"), systemImage: "arrow.down.circle")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                }
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text(L10n.t("正在下载更新…") + " \(Int(progress * 100))%")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }
            case .verifying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在校验 SHA-256…")).font(.footnote)
                }
            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在安装并重启…")).font(.footnote)
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(Palette.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.t("重试下载")) { model.downloadAndInstallUpdate() }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(10)
        .background(Palette.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    .font(.title3.bold())
                    .foregroundStyle(Palette.ink)
                Text(L10n.t("SSH 反向代理管理"))
                    .font(.subheadline)
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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(L10n.t("第一步：在设置中确认本地代理；第二步：添加服务器并填写 SSH 信息。"))
                    .font(.footnote)
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
                            .font(.body.weight(.semibold))
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
                    get: { model.currentProfileId },
                    set: { if let id = $0 { model.selectProfile(id) } }
                )) {
                    ForEach(model.profiles) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.large)
                .accessibilityLabel(L10n.t("选择当前服务器"))

                Divider()

                Text(model.overallPresentation.detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(isDynamicMode ? L10n.t("Mac 网络出口") : L10n.t("本地上游 · Mac"))
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                        MonoText(text: localEndpointDisplay)
                        MetaLine(text: L10n.t("模式 · ") + connectionModeLabel)
                        MetaLine(text: localRouteBadge, tone: isDynamicMode ? .orange : nil)
                        if let egress = model.detection.egressIP {
                            MetaLine(text: L10n.t("出口 ") + egress)
                                .help(L10n.t("经本地代理观测到的出口 IP；变化即代表节点切换，应用会自动重新验证"))
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.callout)
                        .foregroundStyle(Palette.muted.opacity(0.7))
                        .padding(.top, 12)
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(isDynamicMode
                             ? (model.currentProfile?.httpAdapterEnabled == true ? L10n.t("Linux Codex HTTP") : L10n.t("Linux SOCKS5"))
                             : L10n.t("Linux 远端代理"))
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                        MonoText(text: remoteEndpointDisplay)
                        MetaLine(text: L10n.t("仅 127.0.0.1 · TCP"), tone: .green)
                        if isDynamicMode && model.currentProfile?.httpAdapterEnabled == true {
                            MonoText(text: "SOCKS5 \(model.currentProfile?.remoteSocksListenDisplay ?? "—")", size: 10)
                            MetaLine(text: adapterBadgeText, tone: adapterBadgeTone)
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
        case .unavailable: return .orange
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
            if let recovery = TunnelStatusPresentation.recoveryDecision(for: model.currentSnapshot) {
                separator
                HealthCheckRow(title: recovery.title, display: recovery.display, detail: recovery.detail)
            }
            separator
            // 显式入口（原为整块隐性点击，可发现性差）：次级链接 + chevron
            HStack {
                Spacer(minLength: 0)
                Button {
                    openSettingsFront(tab: .logs)
                } label: {
                    HStack(spacing: 3) {
                        Text(L10n.t("点击查看日志定位原因"))
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("查看日志"))
            }
            .padding(.vertical, 7)
            .padding(.trailing, 2)
        }
        .padding(.vertical, 4)
    }

    /// magpie Routing 面板的 SwiftUI 版迁移：最近决策 + 可展开原因 + 主动复测。
    @ViewBuilder
    private var recoveryTraceCard: some View {
        let history = model.currentSnapshot.recoveryHistory
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showRecoveryTrace.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Palette.tone(recoveryTone))
                            .frame(width: 7, height: 7)
                        Text(L10n.t("自愈轨迹"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                        Text(String(format: L10n.t("最近 %d 条"), history.count))
                            .font(.caption2)
                            .foregroundStyle(Palette.muted)
                        Spacer(minLength: 4)
                        Image(systemName: showRecoveryTrace ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("自愈轨迹") + "，\(history.count) " + L10n.t("条记录"))
                .accessibilityHint(L10n.t("展开查看每一步自愈原因"))

                if showRecoveryTrace {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(history.enumerated().reversed()), id: \.offset) { _, decision in
                            recoveryRow(decision)
                        }
                    }
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Palette.border)
                            .frame(width: 1)
                            .padding(.vertical, 4)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(spacing: 8) {
                    Button {
                        model.runHealthCheck()
                    } label: {
                        Label(L10n.t("立即复测"), systemImage: "arrow.clockwise")
                            .font(.footnote)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)

                    Button {
                        openSettingsFront(tab: .logs)
                    } label: {
                        Label(L10n.t("查看日志"), systemImage: "list.bullet.rectangle")
                            .font(.footnote)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
        }
    }

    private var recoveryTone: StatusTone {
        model.currentSnapshot.lastRecoveryDecision.map { Palette.recoveryTone($0) } ?? .gray
    }

    private func recoveryRow(_ decision: TunnelRecoveryDecision) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(decision.state.displayName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.tone(Palette.recoveryTone(decision)))
                Text(decision.action.displayName)
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 4)
                Text(decision.decidedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
            }
            if let next = decision.nextActionAt, decision.state == .scheduled {
                Text(L10n.t("下次执行 ") + next.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
            }
            if !decision.reason.isEmpty {
                Text(decision.reason)
                    .font(.caption2)
                    .foregroundStyle(Palette.muted.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(decision.state.displayName)，\(decision.action.displayName)，\(decision.reason)")
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
            return L10n.t("隧道运行中")
        case .unknown: return L10n.t("正在建立 SSH 连接…")
        case .failed: return model.currentSnapshot.phase == .authRequired
            ? L10n.t("需要核对服务器指纹或 SSH 身份验证")
            : L10n.t("SSH 未连接")
        }
    }

    /// 当前远端验证实际使用的目标 host（业务目标或默认 api.openai.com）。
    private var probeTargetHost: String {
        if let raw = model.currentProfile?.probeTargetURL,
           let url = URL(string: raw), let host = url.host {
            return host
        }
        return "api.openai.com"
    }

    private func remoteDetail(for display: HealthCheckDisplay) -> String {
        switch display {
        case .ok:
            let suffix = L10n.t("（仅代表该目标可达）")
            return isDynamicMode
                ? L10n.t("Linux SOCKS5 已通过远端 HTTPS 请求验证") + " → \(probeTargetHost)" + suffix
                : L10n.t("远端代理端到端验证通过") + " → \(probeTargetHost)" + suffix
        case .unknown: return isDynamicMode ? L10n.t("Linux SOCKS5 尚未验证") : L10n.t("远端代理未验证（未验证 ≠ 可用）")
        case .failed: return L10n.t("远端验证失败，请查看日志定位原因")
        }
    }

    private var httpAdapterDisplay: HealthCheckDisplay {
        if model.currentSnapshot.phase == .idle { return .unknown }
        switch model.currentSnapshot.httpAdapterStatus {
        case .verified: return .ok
        case .unavailable: return .failed
        case .notRequested, .checking, .running: return .unknown
        }
    }

    private var httpAdapterDetail: String {
        model.currentSnapshot.httpAdapterDetail ?? L10n.t("等待 SOCKS5 验活后检查 HTTP CONNECT 入口")
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
            .accessibilityHint(L10n.t("只重新验证，不修改任何配置"))
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
        case .busy(let text):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(text).font(.callout)
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
                    .font(.footnote)
            }
            .menuStyle(.borderlessButton)
            .help(L10n.t("复制 Linux SOCKS5 或 HTTP_PROXY 验收命令；不修改服务器配置"))
            Spacer(minLength: 0)
            if let update = model.updateInfo {
                Button {
                    model.openReleasePage()
                } label: {
                    Label(L10n.t("新版本 ") + "v\(update.latestVersion)", systemImage: "arrow.up.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.blue)
                }
                .buttonStyle(.link)
                .help(L10n.t("打开发布页下载新版本"))
            }
            Button {
                openSettingsFront(tab: .logs)
            } label: {
                Label(L10n.t("查看日志"), systemImage: "list.bullet.rectangle")
                    .font(.footnote)
            }
            .buttonStyle(.link)
        }
    }

    private var footer: some View {
        Text(L10n.t("产品重点：随时知道本地代理、SSH 隧道、远端代理各自是否正常，而不是只看到「SSH 已连接」。"))
            .font(.caption2)
            .foregroundStyle(Palette.muted.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }
}
