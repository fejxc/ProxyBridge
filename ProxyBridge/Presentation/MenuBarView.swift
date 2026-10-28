import SwiftUI
import AppKit

/// 菜单栏弹出面板（约 368pt 宽，结构对应原型 01）。
/// 1.8 起职责收敛为「控制 + 摘要」：健康检查默认折叠为一行摘要（失败自动展开），
/// 大段解释交给设置窗口与日志页；流量路径按真实业务流向绘制（Linux 应用 → Mac 出口）。
@MainActor
struct MenuBarView: View {
    @Environment(AppViewModel.self) private var model
    /// 退出二步确认（MenuBarExtra 面板里系统 confirmationDialog 常无法呈现，
    /// 改为面板内联确认条；8 秒无操作自动复位）。
    @State private var confirmQuit = false
    @State private var confirmQuitResetTask: Task<Void, Never>?
    /// 健康检查详情默认折叠；手动展开与「含失败自动展开」取或。
    @State private var showAllChecks = false

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
                RecoveryTraceCard()
                if let tool = model.remoteToolHint {
                    RemoteToolHintCard(tool: tool) {
                        model.runHealthCheck()
                    } onCopy: {
                        model.copyRemoteToolInstallHint()
                    }
                }
                // 流量统计仅静态转发模式渲染：动态 SOCKS5 无诚实数据源，不占面板空间。
                if !model.displaysDynamicMode, let profile = model.currentProfile {
                    TrafficStatsView(
                        session: model.trafficStore.session(for: profile.id),
                        connected: model.currentSnapshot.sshProcessRunning &&
                            [.connected, .degraded].contains(model.currentSnapshot.phase),
                        lifetimeTotal: model.trafficTotals.hasData(for: profile.id)
                            ? model.trafficTotals.totals(for: profile.id).uploadBytes
                                + model.trafficTotals.totals(for: profile.id).downloadBytes
                            : nil
                    )
                }
                actions
                links
            }
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

                TrafficPathView()
            }
        }
    }

    // MARK: 健康摘要（全过折叠为一行；含失败自动展开并点名）

    private var checks: some View {
        let summary = model.healthSummary
        let expanded = showAllChecks || summary.shouldExpandDetails
        return VStack(spacing: 0) {
            summaryHeader(summary, expanded: expanded)
            if expanded {
                // 展开行与摘要消费同一份装配（healthCheckRows），标题永不分叉
                HealthRowsDetailList()
                    .padding(.top, 6)
            }
            if summary.tone != .green {
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
        }
        .padding(.vertical, 4)
    }

    private func summaryHeader(_ summary: HealthSummaryPresentation, expanded: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showAllChecks.toggle() }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Palette.tone(summary.tone))
                    .frame(width: 8, height: 8)
                Text(summary.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                if let detail = summary.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.detail.map { "\(summary.title)，\($0)" } ?? summary.title)
        .accessibilityHint(L10n.t("展开或收起分层检查详情"))
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
}
