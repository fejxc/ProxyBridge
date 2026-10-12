import SwiftUI

/// 通用设置。尚未实现的行为禁用展示。
struct GeneralSettingsView: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "应用行为") {
                VStack(spacing: 0) {
                    settingRow(
                        title: "登录时启动 ProxyBridge",
                        subtitle: "尚未支持；可在系统设置的「登录项」中手动添加应用。"
                    ) {
                        Toggle("登录时启动", isOn: launchBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(true)
                    }
                    divider
                    settingRow(
                        title: "显示连接异常通知",
                        subtitle: "尚未支持；当前请在应用面板与日志中查看连接异常。"
                    ) {
                        Toggle("通知", isOn: notificationBinding)
                            .disabled(true)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    divider
                    settingRow(
                        title: "远端健康检查间隔",
                        subtitle: "周期检查尚未支持；可使用「检查连接」手动验证。"
                    ) {
                        Picker("间隔", selection: remoteIntervalBinding) {
                            ForEach(AppSettings.allowedRemoteIntervals, id: \.self) { seconds in
                                Text("\(seconds) 秒").tag(seconds)
                            }
                        }
                        .frame(width: 110)
                        .disabled(true)
                    }
                    divider
                    settingRow(
                        title: "本地轻量检查间隔",
                        subtitle: "周期检查尚未支持；连接及手动检查时会验证本地代理。"
                    ) {
                        Picker("间隔", selection: localIntervalBinding) {
                            ForEach(AppSettings.allowedLocalIntervals, id: \.self) { seconds in
                                Text("\(seconds) 秒").tag(seconds)
                            }
                        }
                        .frame(width: 110)
                        .disabled(true)
                    }
                    divider
                    settingRow(
                        title: "复制日志时脱敏",
                        subtitle: "遮挡内网 IP、用户@主机、密钥路径与凭据。"
                    ) {
                        Toggle("脱敏", isOn: redactBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }
            }

            InfoBlock(text: "连接和手动检查会验证本地代理、SSH 隧道及远端代理。当前不支持自动重连、周期检查或系统异常通知。")

            SectionCard(title: "关于") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ProxyBridge · SSH 反向代理管理工具")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("版本：1.0.0")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                    Text("通过 SSH 将 Mac 本地代理转发至服务器的回环端口。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.border.opacity(0.6))
            .frame(height: 1)
    }

    private func settingRow<Control: View>(
        title: String,
        subtitle: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)。\(subtitle)")
    }

    // MARK: 绑定

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { model.settings.launchAtLoginRequested },
            set: { on in model.updateSettings { $0.launchAtLoginRequested = on } }
        )
    }

    private var notificationBinding: Binding<Bool> {
        Binding(
            get: { model.settings.showNotifications },
            set: { on in model.updateSettings { $0.showNotifications = on } }
        )
    }

    private var remoteIntervalBinding: Binding<Int> {
        Binding(
            get: { model.settings.remoteCheckIntervalSeconds },
            set: { seconds in model.updateSettings { $0.remoteCheckIntervalSeconds = seconds } }
        )
    }

    private var localIntervalBinding: Binding<Int> {
        Binding(
            get: { model.settings.localCheckIntervalSeconds },
            set: { seconds in model.updateSettings { $0.localCheckIntervalSeconds = seconds } }
        )
    }

    private var redactBinding: Binding<Bool> {
        Binding(
            get: { model.settings.redactLogsOnCopy },
            set: { on in model.updateSettings { $0.redactLogsOnCopy = on } }
        )
    }
}
