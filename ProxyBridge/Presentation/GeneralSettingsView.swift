import SwiftUI

/// 通用设置与系统授权状态。
struct GeneralSettingsView: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "应用行为") {
                VStack(spacing: 0) {
                    settingRow(
                        title: "登录时启动 ProxyBridge",
                        subtitle: model.loginStatusDescription
                    ) {
                        Toggle("登录时启动", isOn: launchBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(model.changingLoginState)
                    }
                    divider
                    settingRow(
                        title: "显示连接异常通知",
                        subtitle: model.notificationStatusDescription
                    ) {
                        Toggle("通知", isOn: notificationBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    divider
                    settingRow(
                        title: "远端健康检查间隔",
                        subtitle: "定期在服务器上通过 curl 验证代理，每次只运行一个探测。"
                    ) {
                        Picker("间隔", selection: remoteIntervalBinding) {
                            ForEach(AppSettings.allowedRemoteIntervals, id: \.self) { seconds in
                                Text("\(seconds) 秒").tag(seconds)
                            }
                        }
                        .frame(width: 110)
                    }
                    divider
                    settingRow(
                        title: "本地轻量检查间隔",
                        subtitle: "定期验证当前隧道使用的本地代理，不登录远端。"
                    ) {
                        Picker("间隔", selection: localIntervalBinding) {
                            ForEach(AppSettings.allowedLocalIntervals, id: \.self) { seconds in
                                Text("\(seconds) 秒").tag(seconds)
                            }
                        }
                        .frame(width: 110)
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

            HStack {
                Button("授权通知") { model.requestNotificationPermission() }
                Button("刷新系统授权状态") { model.refreshSystemStatus() }
            }
            InfoBlock(text: "自动重连由各服务器配置控制。网络故障按 1、2、4 秒逐步退避，最多等待 60 秒；认证或指纹错误不会自动重试。手动断开会停止恢复，睡眠后仅恢复此前允许自动重连的连接。")

            SectionCard(title: "关于") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ProxyBridge · SSH 反向代理管理工具")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("版本：" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                    Text("通过 SSH 将 Mac 本地代理转发至服务器的回环端口。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { model.refreshSystemStatus() }
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
            get: { model.loginLaunchEnabled },
            set: { on in model.setLaunchAtLogin(on) }
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
