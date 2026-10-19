import SwiftUI

/// 通用设置与系统授权状态。
@MainActor
struct GeneralSettingsView: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: L10n.t("应用行为")) {
                VStack(spacing: 0) {
                    settingRow(
                        title: "登录时启动 ProxyBridge",
                        subtitle: model.loginStatusDescription
                    ) {
                        Toggle(L10n.t("登录时启动"), isOn: launchBinding)
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
                        Toggle(L10n.t("通知"), isOn: notificationBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    divider
                    settingRow(
                        title: "远端健康检查间隔",
                        subtitle: "定期在服务器上通过 curl 验证代理，每次只运行一个探测。"
                    ) {
                        Picker(L10n.t("间隔"), selection: remoteIntervalBinding) {
                            ForEach(AppSettings.allowedRemoteIntervals, id: \.self) { seconds in
                                Text("\(seconds) " + L10n.t("秒")).tag(seconds)
                            }
                        }
                        .frame(width: 110)
                    }
                    divider
                    settingRow(
                        title: "本地轻量检查间隔",
                        subtitle: "定期验证当前隧道使用的本地代理，不登录远端。"
                    ) {
                        Picker(L10n.t("间隔"), selection: localIntervalBinding) {
                            ForEach(AppSettings.allowedLocalIntervals, id: \.self) { seconds in
                                Text("\(seconds) " + L10n.t("秒")).tag(seconds)
                            }
                        }
                        .frame(width: 110)
                    }
                    divider
                    settingRow(
                        title: "复制日志时脱敏",
                        subtitle: "遮挡内网 IP、用户@主机、密钥路径与凭据。"
                    ) {
                        Toggle(L10n.t("脱敏"), isOn: redactBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    divider
                    settingRow(
                        title: "启动时检查更新",
                        subtitle: "只读 GitHub 公开接口比对版本号，不上传任何数据；发现新版本时在菜单栏提示。"
                    ) {
                        Toggle(L10n.t("检查更新"), isOn: updateCheckBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    divider
                    settingRow(
                        title: "连接期间防止空闲休眠",
                        subtitle: "有活跃隧道时阻止系统空闲休眠（合盖睡眠不受影响）。断开或退出后立即恢复系统默认。"
                    ) {
                        Toggle(L10n.t("防止休眠"), isOn: keepAwakeBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    divider
                    settingRow(
                        title: "界面语言",
                        subtitle: "切换后立即生效；事件详情与日志文案保持中文。"
                    ) {
                        Picker(L10n.t("界面语言"), selection: languageBinding) {
                            ForEach(AppLanguage.allCases, id: \.self) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .frame(width: 140)
                    }
                }
            }

            HStack {
                Button(L10n.t("授权通知")) { model.requestNotificationPermission() }
                Button(L10n.t("刷新系统授权状态")) { model.refreshSystemStatus() }
            }
            InfoBlock(text: "自动重连由各服务器配置控制。网络故障按 1、2、4 秒逐步退避，最多等待 60 秒；网络路径恢复（Wi-Fi 重连等）会立即重建允许自动重连的连接，不再等 SSH 存活超时。认证或指纹错误不会自动重试。手动断开会停止恢复，睡眠后仅恢复此前允许自动重连的连接。")

            SectionCard(title: L10n.t("关于")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("ProxyBridge · SSH 反向代理管理工具"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("版本：" + AppViewModel.currentVersion)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                    if let update = model.updateInfo {
                        Text(L10n.t("有新版本 ") + "v\(update.latestVersion)" + L10n.t(" 可用"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Palette.blue)
                    }
                    Text(L10n.t("通过 SSH 将 Mac 本地代理转发至服务器的回环端口。"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.t("检查更新")) {
                            Task { await model.checkForUpdates(manual: true) }
                        }
                        .disabled(model.updateCheckUIState == .checking)
                        if model.updateCheckUIState == .checking {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.t("正在检查…"))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                        }
                        if model.updateInfo != nil {
                            Button(L10n.t("打开发布页")) { model.openReleasePage() }
                        }
                    }
                    .padding(.top, 4)
                    // 手动检查的可见反馈（此前只写日志，界面无感）
                    switch model.updateCheckUIState {
                    case .failed(let reason):
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.red)
                            .fixedSize(horizontal: false, vertical: true)
                    case .idle:
                        if let update = model.updateInfo {
                            Text(L10n.t("发现新版本 v") + update.latestVersion + L10n.t("（当前 v") + AppViewModel.currentVersion + L10n.t("）"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.blue)
                        } else {
                            Text(L10n.t("已是最新版本（v") + AppViewModel.currentVersion + L10n.t("）"))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                        }
                    case .checking:
                        EmptyView()
                    }
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

    private var updateCheckBinding: Binding<Bool> {
        Binding(
            get: { model.settings.checkForUpdates },
            set: { on in model.updateSettings { $0.checkForUpdates = on } }
        )
    }

    private var keepAwakeBinding: Binding<Bool> {
        Binding(
            get: { model.settings.keepAwakeWhileConnected },
            set: { on in model.updateSettings { $0.keepAwakeWhileConnected = on } }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.settings.language },
            set: { lang in model.updateSettings { $0.language = lang } }
        )
    }
}
