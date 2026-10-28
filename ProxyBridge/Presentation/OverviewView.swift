import SwiftUI
import AppKit

/// 概览页（设置窗口首页）：先看运行状态，再点进配置。
/// 健康明细行、流量路径、自愈轨迹与菜单栏共用同一套组件与 ViewModel 装配，
/// 避免「菜单栏 / 概览 / 日志」对成功、警告、不可用的定义分叉。
@MainActor
struct OverviewView: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        if model.profiles.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                statusCard
                TrafficPathView()
                actions
                connectionInfoCard
                // 流量统计仅静态转发：动态 SOCKS5 无诚实数据源（同菜单栏约定）
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
                RecoveryTraceCard()
                linksRow
            }
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("尚未配置服务器"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(L10n.t("添加服务器并填写 SSH 信息后，这里会显示连接路径与健康状态。"))
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.requestCreateProfile()
                } label: {
                    Label(L10n.t("添加服务器"), systemImage: "plus")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: 服务器头卡

    private var headerCard: some View {
        SectionCard {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Palette.softFill)
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.muted)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.currentProfile?.name ?? "—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    MonoText(text: model.currentProfile?.displayTarget ?? "—", weight: .medium, size: 11)
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                StatusTag(text: model.overallPresentation.title, tone: model.overallPresentation.tone)
                Button {
                    model.openSettings(tab: .servers)
                } label: {
                    Label(L10n.t("编辑配置"), systemImage: "pencil")
                }
                .controlSize(.regular)
                .buttonStyle(.bordered)
                .accessibilityLabel(L10n.t("编辑服务器配置"))
            }
            if !model.overallPresentation.detail.isEmpty {
                Divider()
                Text(model.overallPresentation.detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 三层健康（展开态明细）

    private var statusCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Palette.tone(model.healthSummary.tone))
                        .frame(width: 8, height: 8)
                    Text(model.healthSummary.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 4)
                    if let detail = model.healthSummary.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .accessibilityElement(children: .combine)
                HealthRowsDetailList()
            }
        }
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

    // MARK: 连接信息

    private var connectionInfoCard: some View {
        GroupBox(L10n.t("连接信息")) {
            VStack(spacing: 10) {
                infoRow(L10n.t("服务器地址"), mono: serverAddress)
                infoRow(L10n.t("用户名"), value: model.currentProfile?.username ?? "—")
                infoRow(L10n.t("认证方式"), value: model.currentProfile?.authMode.displayName ?? "—")
                if let profile = model.currentProfile, let since = model.connectedSince[profile.id] {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        infoRow(
                            L10n.t("连接时长"),
                            value: TrafficStatsView.duration(context.date.timeIntervalSince(since))
                        )
                    }
                }
            }
        }
    }

    private var serverAddress: String {
        guard let profile = model.currentProfile else { return "—" }
        return "\(profile.host):\(profile.sshPort)"
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
        }
    }

    private func infoRow(_ label: String, mono: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            MonoText(text: mono, size: 12)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
        }
    }

    // MARK: 链接行

    private var linksRow: some View {
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
            Button {
                model.openSettings(tab: .logs)
            } label: {
                Label(L10n.t("查看日志"), systemImage: "list.bullet.rectangle")
                    .font(.footnote)
            }
            .buttonStyle(.link)
        }
    }
}

// MARK: - 共享：流量路径（方向 = 真实业务流向）

/// 纵向流量路径：Linux 应用 → SSH 反向隧道（→ Mac 本地代理）→ Mac 网络出口。
/// 菜单栏面板与概览页共用。
@MainActor
struct TrafficPathView: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        SectionCard {
            if model.displaysDynamicMode {
                dynamicPath
            } else {
                staticPath
            }
        }
    }

    @ViewBuilder
    private var dynamicPath: some View {
        pathNode(title: L10n.t("Linux 应用")) {
            MonoText(text: remoteEndpointDisplay)
            MetaLine(text: L10n.t("监听在 Linux 本机 · 仅 127.0.0.1"), tone: .green)
            if model.currentProfile?.httpAdapterEnabled == true {
                MonoText(text: "HTTP \(model.currentProfile?.remoteHTTPListenDisplay ?? "—")", size: 11)
                    .foregroundStyle(Palette.muted)
                MetaLine(text: adapterBadgeText, tone: adapterBadgeTone)
            }
        }
        pathEdge(label: L10n.t("SSH 反向隧道"))
        pathNode(title: L10n.t("Mac 网络出口")) {
            Text(L10n.t("使用 Mac 当前网络栈（系统网络 / Clash TUN）"))
                .font(.footnote)
                .foregroundStyle(Palette.ink)
            MetaLine(text: L10n.t("模式 · ") + connectionModeLabel)
            if let egress = model.detection.egressIP {
                MetaLine(text: L10n.t("出口 ") + egress)
                    .help(L10n.t("经本地代理观测到的出口 IP；变化即代表节点切换，应用会自动重新验证"))
            }
            if let profile = model.currentProfile, let since = model.connectedSince[profile.id] {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    MetaLine(text: L10n.t("会话时长 ") + TrafficStatsView.duration(context.date.timeIntervalSince(since)))
                }
            }
        }
    }

    @ViewBuilder
    private var staticPath: some View {
        pathNode(title: L10n.t("Linux 应用")) {
            MonoText(text: remoteEndpointDisplay)
            MetaLine(text: L10n.t("监听在 Linux 本机 · 仅 127.0.0.1"), tone: .green)
        }
        pathEdge(label: L10n.t("SSH 反向隧道"))
        pathNode(title: L10n.t("Mac 本地代理")) {
            MonoText(text: localEndpointDisplay)
            MetaLine(text: localRouteBadge)
        }
        pathEdge(label: L10n.t("本机出站"))
        pathNode(title: L10n.t("Mac 网络出口")) {
            if let egress = model.detection.egressIP {
                MetaLine(text: L10n.t("出口 ") + egress)
                    .help(L10n.t("经本地代理观测到的出口 IP；变化即代表节点切换，应用会自动重新验证"))
            } else {
                MetaLine(text: L10n.t("经系统网络栈出站"))
            }
        }
    }

    /// 静态转发模式下的 Mac 本地代理端点（动态模式不渲染该节点）。
    private var localEndpointDisplay: String {
        guard let profile = model.currentProfile else { return "—" }
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

    private var localRouteBadge: String {
        if model.currentSnapshot.effectiveMode == .staticForward { return L10n.t("本地入口已通过实测") }
        return model.resolvedEndpointDescription
    }

    private var remoteEndpointDisplay: String {
        guard let profile = model.currentProfile else { return "—" }
        if model.displaysDynamicMode {
            return profile.httpAdapterEnabled
                ? "HTTP \(profile.remoteHTTPListenDisplay)"
                : "SOCKS5 \(profile.remoteSocksListenDisplay)"
        }
        let endpoint = model.currentSnapshot.activeLocalEndpoint
        return "\(ServerProfile.remoteBindHost):\(profile.remotePort) · \(endpoint?.protocol.displayName ?? profile.preferredProtocol.displayName)"
    }

    private var connectionModeLabel: String {
        if model.displaysDynamicMode { return ConnectionMode.reverseDynamic.displayName }
        if model.currentSnapshot.effectiveMode == .staticForward { return ConnectionMode.staticForward.displayName }
        return model.currentProfile?.connectionMode.displayName ?? "—"
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

    private func pathNode<V: View>(title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            content()
        }
    }

    private func pathEdge(label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.muted.opacity(0.7))
            Text(label)
                .font(.caption2)
                .foregroundStyle(Palette.muted)
        }
        .padding(.leading, 2)
    }
}

// MARK: - 共享：健康检查行明细列表

/// 展开态健康行：菜单栏折叠展开与概览页共用同一装配（healthCheckRows）。
@MainActor
struct HealthRowsDetailList: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        let rows = model.healthCheckRows
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Palette.border.opacity(0.6))
                        .frame(height: 1)
                }
                HealthCheckRow(
                    title: row.title,
                    display: row.display,
                    detail: model.healthRowDetail(index: index, display: row.display)
                )
            }
        }
    }
}

// MARK: - 共享：自愈轨迹卡

/// 最近自愈决策 + 可展开原因 + 主动复测。菜单栏与概览页共用。
@MainActor
struct RecoveryTraceCard: View {
    @Environment(AppViewModel.self) private var model
    @State private var showTrace = false

    var body: some View {
        let history = model.currentSnapshot.recoveryHistory
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showTrace.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Palette.tone(traceTone))
                            .frame(width: 7, height: 7)
                        Text(L10n.t("自愈轨迹"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                        Text(String(format: L10n.t("最近 %d 条"), history.count))
                            .font(.caption2)
                            .foregroundStyle(Palette.muted)
                        Spacer(minLength: 4)
                        Image(systemName: showTrace ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("自愈轨迹") + "，\(history.count) " + L10n.t("条记录"))
                .accessibilityHint(L10n.t("展开查看每一步自愈原因"))

                if showTrace {
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
                        model.openSettings(tab: .logs)
                        NSApplication.shared.activate(ignoringOtherApps: true)
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

    private var traceTone: StatusTone {
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
}
