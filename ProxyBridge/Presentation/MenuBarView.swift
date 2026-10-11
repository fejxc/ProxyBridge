import SwiftUI

/// 菜单栏弹出面板（约 368pt 宽，结构对应原型 01）。
struct MenuBarView: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.isDemoMode {
                DemoModeBanner()
            }
            if model.profiles.isEmpty {
                emptyState
            } else {
                serverCard
                checks
                actions
                links
            }
            footer
        }
        .padding(16)
        .frame(width: 368)
        .background(Palette.background)
    }

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
                Text("SSH 反向代理管理")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                model.openSettings(tab: .servers)
            })
            .help("打开设置")
            .accessibilityLabel("打开设置")
        }
    }

    // MARK: 空状态（首次使用引导，UI-SPEC 2.3 的空状态替代）

    private var emptyState: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("尚未配置服务器")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("第一步：在设置中确认本地代理；第二步：添加服务器并填写 SSH 信息。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink {
                    Label("打开设置，添加服务器", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .simultaneousGesture(TapGesture().onEnded {
                    model.openSettings(tab: .servers)
                })
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

                Picker("选择服务器", selection: Binding(
                    get: { model.currentProfileId ?? UUID() },
                    set: { model.selectProfile($0) }
                )) {
                    ForEach(model.profiles) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.large)
                .accessibilityLabel("选择当前服务器")

                Divider()

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("本地代理 · Mac")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                        MonoText(text: localEndpointDisplay)
                        MiniBadge(text: model.resolvedEndpointDescription, tone: .blue)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.muted.opacity(0.7))
                        .padding(.top, 12)
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("远程监听 · Linux")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                        MonoText(text: model.currentProfile?.remoteListenDisplay ?? "—")
                        MiniBadge(text: "仅本机回环", tone: .green)
                    }
                }
            }
        }
    }

    private var localEndpointDisplay: String {
        guard let profile = model.currentProfile else { return "—" }
        switch EndpointResolver.resolve(profile: profile, detection: model.detection) {
        case .manual(let ep), .auto(let ep):
            return ep.displayEndpoint
        case .none:
            return "未解析"
        }
    }

    // MARK: 三层健康

    private var checks: some View {
        let triad = model.healthTriad
        return VStack(spacing: 0) {
            HealthCheckRow(title: "本地代理", display: triad.local, detail: localDetail(for: triad.local))
            separator
            HealthCheckRow(title: "SSH 隧道", display: triad.ssh, detail: sshDetail(for: triad.ssh))
            separator
            HealthCheckRow(title: "远端代理", display: triad.remote, detail: remoteDetail(for: triad.remote))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            model.openSettings(tab: .logs)
        }
        .help("点击查看日志定位原因")
    }

    private var separator: some View {
        Rectangle()
            .fill(Palette.border.opacity(0.6))
            .frame(height: 1)
    }

    private func localDetail(for display: HealthCheckDisplay) -> String {
        switch display {
        case .ok: return "本地代理已通过协议验证（演示）"
        case .unknown: return "尚未验证本地代理可用性"
        case .failed: return "本地代理验证失败：请确认代理已启动或改用手动配置"
        }
    }

    private func sshDetail(for display: HealthCheckDisplay) -> String {
        switch display {
        case .ok:
            let base = "隧道运行中"
            return model.isDemoMode ? base + "（演示，未启动真实 SSH）" : base
        case .unknown: return "正在建立 SSH 连接…"
        case .failed: return model.currentSnapshot.phase == .authRequired
            ? "需要核对服务器指纹或 SSH 密钥"
            : "SSH 未连接"
        }
    }

    private func remoteDetail(for display: HealthCheckDisplay) -> String {
        switch display {
        case .ok: return "远端代理端到端验证通过（演示）"
        case .unknown: return "远端代理未验证（未验证 ≠ 可用）"
        case .failed: return "远端验证失败，请查看日志定位原因"
        }
    }

    // MARK: 操作

    private var actions: some View {
        HStack(spacing: 8) {
            primaryButton
            Button {
                model.runHealthCheck()
            } label: {
                Label("检查连接", systemImage: "arrow.triangle.2.circlepath")
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
                Label("连接服务器", systemImage: "arrow.up.forward")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        case .disconnect:
            Button(role: .destructive) {
                model.disconnect()
            } label: {
                Label("断开连接", systemImage: "stop.fill")
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
            Button {
                model.copyRemoteCommandToPasteboard()
            } label: {
                Label("复制远端代理命令", systemImage: "doc.on.doc")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.link)
            .accessibilityHint("复制 export 环境变量示例，不修改服务器配置")
            Spacer(minLength: 0)
            SettingsLink {
                Label("查看日志", systemImage: "list.bullet.rectangle")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.link)
            .simultaneousGesture(TapGesture().onEnded {
                model.openSettings(tab: .logs)
            })
        }
    }

    private var footer: some View {
        Text("产品重点：随时知道本地代理、SSH 隧道、远端代理各自是否正常，而不是只看到「SSH 已连接」。")
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.muted.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 小徽标（原型 mini-qual）。
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
