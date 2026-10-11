import SwiftUI

/// 「通用设置」Tab。登录启动在阶段 D 通过 SMAppService 真正落地；
/// 阶段 A 的开关只保存用户意图并明确标注未生效。
struct GeneralSettingsView: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "应用行为") {
                VStack(spacing: 0) {
                    settingRow(
                        title: "登录时启动 ProxyBridge",
                        subtitle: "使用系统登录项（SMAppService），需要 macOS 用户授权。"
                    ) {
                        Toggle("登录时启动", isOn: launchBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(true) // 阶段 D 实现；当前不可用
                    }
                    divider
                    settingRow(
                        title: "显示连接异常通知",
                        subtitle: "连接失败、认证问题或长时间降级时提醒。"
                    ) {
                        Toggle("通知", isOn: notificationBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    divider
                    settingRow(
                        title: "远端健康检查间隔",
                        subtitle: "远端探测依赖远程 curl 可用；避免过度探测。"
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
                        subtitle: "只检查本地代理可用性，不触碰远端。"
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

            InfoBlock(text: "「登录时启动」将在阶段 D 接入 SMAppService 注册（可随时在 系统设置 → 通用 → 登录项 中管理）。当前开关仅保存你的偏好，尚未向系统注册，也不会在未授权时自动启动连接。")

            SectionCard(title: "关于") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ProxyBridge · SSH 反向代理管理工具")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("版本：MVP 0.1.0 · 阶段 A（工程与 UI）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                    Text("阶段状态：工程与 UI 已实现 · 本地代理真实检测（阶段 B）开发中 · SSH 隧道（阶段 C）开发中 · 稳定性与登录启动（阶段 D）未开始")
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
