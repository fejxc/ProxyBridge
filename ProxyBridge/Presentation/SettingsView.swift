import SwiftUI

/// 设置窗口（约 960×680）：系统 NavigationSplitView 双栏 + 五个分区，概览为首页（原型 02）。
@MainActor
struct SettingsView: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            content
        }
        .frame(minWidth: 860, minHeight: 600)
        .preferredColorScheme(nil) // 跟随系统深浅色
    }

    // MARK: 侧栏（原生 List：半透明侧栏材质 + 系统选中态）

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.settingsTab },
            set: { model.openSettings(tab: $0) }
        )) {
            Section {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .tag(tab)
                }
            }
            Section {
                ForEach(model.profiles) { profile in
                    Button {
                        model.selectProfile(profile.id)
                        model.openSettings(tab: .servers)
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(profileColor(profile.id))
                                .frame(width: 7, height: 7)
                            Text(profile.name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("服务器 \(profile.name)\(isConnected(profile.id) ? "，已连接" : "")")
                }
                Button {
                    model.openSettings(tab: .servers)
                    model.requestCreateProfile()
                } label: {
                    Label(L10n.t("添加服务器"), systemImage: "plus")
                }
            } header: {
                HStack {
                    Text(L10n.t("我的服务器"))
                    Spacer()
                    Text("\(model.profiles.count)")
                        .monospacedDigit()
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func profileColor(_ id: UUID) -> Color {
        isConnected(id) ? Palette.green : Palette.muted.opacity(0.6)
    }

    private func isConnected(_ id: UUID) -> Bool {
        let phase = model.snapshots[id]?.phase
        return phase == .connected || phase == .degraded
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
                case .overview:
                    OverviewView()
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Palette.background)
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
        case .overview: return L10n.t("概览")
        case .servers: return L10n.t("服务器配置")
        case .proxy: return L10n.t("本地代理")
        case .logs: return L10n.t("连接日志")
        case .general: return L10n.t("通用设置")
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return L10n.t("服务器运行状态与连接路径。")
        case .servers: return L10n.t("管理 SSH 主机、身份认证及远程监听端口。")
        case .proxy: return L10n.t("读取本机系统代理设置，验证可用协议与监听端口。")
        case .logs: return L10n.t("显示最近的事件、健康检查与错误原因。")
        case .general: return L10n.t("管理启动、健康检查以及默认行为。")
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge"
        case .servers: return "square.stack.3d.up"
        case .proxy: return "point.3.filled.connected.trianglepath.dotted"
        case .logs: return "list.bullet.rectangle"
        case .general: return "gearshape"
        }
    }
}
