import SwiftUI

/// 设置窗口（约 960×680）：左侧栏 + 四个分区（原型 02）。
@MainActor
struct SettingsView: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.background)
        }
        .frame(minWidth: 860, minHeight: 600)
        .preferredColorScheme(nil) // 跟随系统深浅色
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("设置"))
                .font(.footnote.weight(.bold))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 6)

            ForEach(SettingsTab.allCases) { tab in
                SidebarButton(
                    title: tab.title,
                    symbol: tab.symbol,
                    isActive: model.settingsTab == tab
                ) {
                    model.openSettings(tab: tab)
                }
            }

            Spacer(minLength: 12)

            HStack {
                Text(L10n.t("我的服务器"))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Text("\(model.profiles.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.profiles) { profile in
                        SidebarProfileRow(
                            name: profile.name,
                            isCurrent: profile.id == model.currentProfileId,
                            isConnected: {
                                let phase = model.snapshots[profile.id]?.phase
                                return phase == .connected || phase == .degraded
                            }()
                        ) {
                            model.selectProfile(profile.id)
                            model.openSettings(tab: .servers)
                        }
                    }
                    Button {
                        model.openSettings(tab: .servers)
                        model.requestCreateProfile()
                    } label: {
                        Label(L10n.t("添加服务器"), systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 6)
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 220)
        }
        .padding(.bottom, 14)
        .frame(width: 210, alignment: .leading)
        .background(Palette.softFill)
    }

    // MARK: 内容区

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleBar
                // 密码请求卡放在设置窗口顶部：面板关闭时用户也不会错过
                if model.pendingPasswordProfileId != nil {
                    PasswordPromptCard()
                }
                switch model.settingsTab {
                case .servers:
                    ServerEditorView()
                case .proxy:
                    ProxySettingsView()
                case .logs:
                    LogsView()
                case .general:
                    GeneralSettingsView()
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var titleBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.settingsTab.title)
                    .font(.title2.bold())
                    .foregroundStyle(Palette.ink)
                Text(model.settingsTab.subtitle)
                    .font(.callout)
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 12)
            StatusTag(text: model.overallPresentation.title, tone: model.overallPresentation.tone)
        }
    }
}

extension SettingsTab {
    var title: String {
        switch self {
        case .servers: return L10n.t("服务器配置")
        case .proxy: return L10n.t("本地代理")
        case .logs: return L10n.t("连接日志")
        case .general: return L10n.t("通用设置")
        }
    }

    var subtitle: String {
        switch self {
        case .servers: return L10n.t("管理 SSH 主机、身份认证及远程监听端口。")
        case .proxy: return L10n.t("读取本机系统代理设置，验证可用协议与监听端口。")
        case .logs: return L10n.t("显示最近的事件、健康检查与错误原因。")
        case .general: return L10n.t("管理启动、健康检查以及默认行为。")
        }
    }

    var symbol: String {
        switch self {
        case .servers: return "square.stack.3d.up"
        case .proxy: return "point.3.filled.connected.trianglepath.dotted"
        case .logs: return "list.bullet.rectangle"
        case .general: return "gearshape"
        }
    }
}

// MARK: 侧栏小组件

@MainActor
struct SidebarButton: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.callout)
                    .frame(width: 18)
                Text(title)
                    .font(.callout.weight(isActive ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isActive ? Palette.blue : Palette.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(isActive ? Palette.blue.opacity(0.1) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

@MainActor
struct SidebarProfileRow: View {
    let name: String
    let isCurrent: Bool
    let isConnected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(isConnected ? Palette.green : Palette.muted.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isCurrent ? Palette.blue : Palette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isCurrent ? Palette.blue.opacity(0.08) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("服务器 \(name)\(isConnected ? "，已连接" : "")")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
