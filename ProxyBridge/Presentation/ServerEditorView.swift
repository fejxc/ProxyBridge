import SwiftUI
import AppKit

/// 服务器编辑表单（设置窗口「服务器」Tab，对应原型 tab-servers）。
/// 外层管理草稿生命周期（新建/切换/保存/删除），内层表单只读写 Binding。
@MainActor
struct ServerEditorView: View {
    @Environment(AppViewModel.self) private var model

    @State private var draft: ServerProfile?
    /// 草稿对应的原始值（未保存变更检测）。
    @State private var lastLoaded: ServerProfile?
    @State private var showUnsavedBanner = false
    /// ~/.ssh/config 导入面板。
    @State private var importEntries: [SSHConfigEntry]?

    var body: some View {
        Group {
            if draft != nil {
                editorForm
            } else {
                emptyPane
            }
        }
        .sheet(isPresented: Binding(
            get: { importEntries != nil },
            set: { if !$0 { importEntries = nil } }
        )) {
            if let entries = importEntries {
                SSHConfigImportSheet(entries: entries)
            }
        }
        .task(id: editSourceId) {
            if showUnsavedProtection, let current = draft, let baseline = lastLoaded,
               current != baseline {
                // 保留用户正在编辑的草稿，改为提示；绝不静默丢弃
                showUnsavedBanner = true
                return
            }
            showUnsavedBanner = false
            loadDraft()
        }
    }

    /// 未保存保护仅在「编辑已有服务器」时启用；新建草稿本身就是临时的。
    private var showUnsavedProtection: Bool { !model.editorIsNewDraft }

    private var emptyPane: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t("未选择服务器"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(L10n.t("添加一台服务器开始使用：填写名称、SSH 主机、端口、用户名即可（首次连接时可在应用内核对并信任主机指纹，也可在终端先 ssh 一次）。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        model.requestCreateProfile()
                    } label: {
                        Label(L10n.t("添加服务器"), systemImage: "plus")
                    }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    Button {
                        importEntries = model.availableSSHConfigEntries()
                    } label: {
                        Label(L10n.t("从 ~/.ssh/config 导入"), systemImage: "square.and.arrow.down.on.square")
                    }
                    .controlSize(.regular)
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private var editorForm: some View {
        let draftBinding = Binding<ServerProfile>(
            get: { draft ?? .placeholder },
            set: { draft = $0 }
        )
        return VStack(alignment: .leading, spacing: 16) {
            if showUnsavedBanner {
                InfoBlock(text: "正在编辑「\(draftBinding.wrappedValue.name)」的未保存修改：这些修改尚未写入磁盘。切换左侧服务器不会丢弃它们，但当前显示的是草稿而非已保存配置。")
            }
            ServerEditorForm(
                profile: draftBinding,
                isNew: model.editorIsNewDraft,
                snapshotPhase: model.snapshots[draftBinding.wrappedValue.id]?.phase,
                hasStoredPassword: model.hasStoredPassword(for: draftBinding.wrappedValue.id),
                onForgetStoredPassword: { model.forgetStoredPassword() },
                onSave: { profile in
                    guard ServerProfileRule.validate(profile).isValid else { return }
                    if model.saveDraftProfile(profile) {
                        self.draft = profile
                        self.lastLoaded = profile
                        self.showUnsavedBanner = false
                    }
                },
                onDiscard: {
                    model.discardDraft()
                    self.draft = nil
                },
                onDelete: { profile in
                    model.deleteProfile(profile.id)
                    self.draft = nil
                }
            )
        }
    }

    private var editSourceId: String {
        if model.editorIsNewDraft { return "new" }
        return model.currentProfileId?.uuidString ?? "none"
    }

    private func loadDraft() {
        if model.editorIsNewDraft {
            draft = model.makeNewProfileDraft()
        } else {
            draft = model.currentProfile
        }
        lastLoaded = draft
        showUnsavedBanner = false
    }
}

extension ServerProfile {
    /// 绑定兜底值（表单只在 draft != nil 时渲染，正常不会用到）。
    static let placeholder = ServerProfile(
        name: "", host: "", sshPort: 22, username: "", remotePort: 7890
    )
}

/// ~/.ssh/config 导入面板（P2）：列出可导入条目，勾选后创建服务器配置。
/// 只读取 HostName / Port / User / IdentityFile 四个指令，其他指令不迁移。
@MainActor
private struct SSHConfigImportSheet: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entries: [SSHConfigEntry]
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("从 ~/.ssh/config 导入"))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.ink)
            Text(L10n.t("仅读取 HostName / Port / User / IdentityFile；导入后可再编辑。与既有配置同主机、同端口、同用户名的条目自动跳过。"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(entries) { entry in
                        Button {
                            if selected.contains(entry.alias) { selected.remove(entry.alias) }
                            else { selected.insert(entry.alias) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(entry.alias) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(entry.alias) ? Palette.blue : Palette.muted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.alias)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Palette.ink)
                                    MonoText(
                                        text: "\(entry.hostName ?? entry.alias):\(entry.port ?? 22)" +
                                            (entry.user.map { " · \($0)" } ?? "") +
                                            (entry.identityFile.map { " · \($0)" } ?? ""),
                                        size: 10
                                    )
                                    .foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .background(Palette.softFill)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack {
                Button(L10n.t("全选")) {
                    selected = Set(entries.map(\.alias))
                }
                .buttonStyle(.link)
                Spacer()
                Button(L10n.t("取消")) { dismiss() }
                    .buttonStyle(.bordered)
                Button(L10n.t("导入选中（") + "\(selected.count)") {
                    let picked = entries.filter { selected.contains($0.alias) }
                    _ = model.importSSHConfigEntries(picked)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { selected = Set(entries.map(\.alias)) } // 默认全选
    }
}

/// 表单主体。
@MainActor
struct ServerEditorForm: View {
    @Binding var profile: ServerProfile
    let isNew: Bool
    let snapshotPhase: TunnelPhase?
    let hasStoredPassword: Bool
    let onForgetStoredPassword: () -> Void
    let onSave: (ServerProfile) -> Void
    let onDiscard: () -> Void
    let onDelete: (ServerProfile) -> Void

    @State private var confirmDelete = false

    private var validation: ProfileValidation { ServerProfileRule.validate(profile) }

    private var needsReconnect: Bool {
        snapshotPhase == .connected || snapshotPhase == .degraded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if needsReconnect && !isNew {
                InfoBlock(text: "此服务器当前有活跃连接：修改主机 / 端口 / 认证 / 远程监听端口后，需断开并重连才能生效（旧隧道仍按旧配置运行）。")
            }

            SectionCard(title: L10n.t("基本信息")) {
                VStack(spacing: 14) {
                    FormRow(label: "服务器名称", help: "1–40 字符，用于识别") {
                        TextField(L10n.t("例如：实验室 GPU 服务器"), text: $profile.name)
                    }
                    FormRow(label: "SSH 主机", help: "IP 或域名；暂不支持 IPv6 字面量与包含空白的主机") {
                        TextField(L10n.t("10.x.x.x 或 example.com"), text: $profile.host)
                            .autocorrectionDisabled()
                    }
                    FormRow(label: "SSH 端口") {
                        PortField(value: $profile.sshPort, prompt: "SSH 端口")
                    }
                    FormRow(label: "用户名") {
                        TextField(L10n.t("SSH 用户名"), text: $profile.username)
                            .autocorrectionDisabled()
                    }
                    FormRow(label: "认证方式") {
                        Picker(L10n.t("认证方式"), selection: $profile.authMode) {
                            ForEach(AuthenticationMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if profile.authMode == .password {
                        FormRow(label: "SSH 密码", help: nil) {
                            VStack(alignment: .leading, spacing: 8) {
                                InfoBlock(text: "连接时会在面板中请求输入密码。勾选「记住密码」后密码存入本机钥匙串（系统加密存储），绝不写入 profiles.json 或日志；认证失败会自动清除已存密码。")
                                Toggle(L10n.t("记住密码（存入本机钥匙串）"), isOn: Binding(
                                    get: { profile.rememberPassword },
                                    set: { on in
                                        profile.rememberPassword = on
                                        if !on { onForgetStoredPassword() }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11))
                                if hasStoredPassword {
                                    HStack(spacing: 8) {
                                        Label(L10n.t("已记住密码（本机钥匙串）"), systemImage: "checkmark.seal.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Palette.green)
                                        Button(L10n.t("忘记密码")) {
                                            onForgetStoredPassword()
                                        }
                                        .buttonStyle(.link)
                                        .font(.system(size: 11))
                                    }
                                }
                            }
                        }
                    }
                    if profile.authMode == .identityFile {
                        FormRow(label: "密钥路径", help: "仅引用本机私钥文件路径；不读取、不上传、不保存密钥内容。") {
                            HStack(spacing: 8) {
                                TextField("~/.ssh/id_ed25519", text: Binding(
                                    get: { profile.identityFilePath ?? "" },
                                    set: { profile.identityFilePath = $0.isEmpty ? nil : $0 }
                                ))
                                .autocorrectionDisabled()
                                Button(L10n.t("浏览…")) { browseKeyFile() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }

            SectionCard(title: L10n.t("反向代理配置")) {
                VStack(spacing: 14) {
                    FormRow(label: "连接模式", help: "自动模式优先使用真实验证通过的本地代理，否则切换到 OpenSSH 动态 SOCKS5。") {
                        Picker(L10n.t("连接模式"), selection: $profile.connectionMode) {
                            ForEach(ConnectionMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 190, alignment: .leading)
                    }
                    if profile.connectionMode != .reverseDynamic {
                        FormRow(label: "静态转发端口", help: "Linux 127.0.0.1:<端口> 会转发到 Mac 上已验证的 HTTP、SOCKS5 或 Mixed 入口。") {
                            loopbackPortField($profile.remotePort, prompt: "HTTP/SOCKS 端口")
                        }
                    }
                    if profile.connectionMode != .staticForward {
                        FormRow(label: "动态 SOCKS5 端口", help: "OpenSSH 原生反向动态转发；不需要 Mac 本地代理端口，只支持 TCP。") {
                            loopbackPortField($profile.remoteSocksPort, prompt: "SOCKS5 端口")
                        }
                        FormRow(label: "HTTP 兼容入口", help: "默认在 Linux 127.0.0.1:7890 提供 Codex HTTP_PROXY/HTTPS_PROXY；由 App 在 Mac 侧实现 HTTP 代理语义，服务器零依赖（无需安装 Privoxy）。不会安装软件或修改系统配置。") {
                            VStack(alignment: .leading, spacing: 7) {
                                Toggle(L10n.t("提供 HTTP 入口（Codex 继续使用 7890）"), isOn: $profile.httpAdapterEnabled)
                                    .controlSize(.small)
                                if profile.httpAdapterEnabled {
                                    loopbackPortField($profile.remoteHTTPPort, prompt: "HTTP 端口")
                                    Text(L10n.t("主路径验证通过后立即实测 HTTP CONNECT；入口异常时主路径不受影响。"))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Palette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    FormRow(label: "本地代理") {
                        Text(proxySummary)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                    }
                    if profile.connectionMode != .reverseDynamic {
                        FormRow(label: "流量统计 Relay", help: "仅用于静态转发；动态 SOCKS5 的 SSH 业务流量不通过此 Relay 统计。") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(L10n.t("固定本地 Relay 端口"), isOn: Binding(get: { profile.relayPort != nil }, set: { profile.relayPort = $0 ? 17997 : nil }))
                            if profile.relayPort != nil {
                                PortField(value: Binding(get: { profile.relayPort ?? 17997 }, set: { profile.relayPort = $0 }), prompt: "Relay 端口")
                            }
                        }
                        }
                    }
                    FormRow(label: "首选协议", help: "自动检测模式下优先采用该协议的实测结果；手动模式以手动端点为准。") {
                        Picker(L10n.t("首选协议"), selection: $profile.preferredProtocol) {
                            Text("HTTP").tag(ProxyProtocol.http)
                            Text("SOCKS5").tag(ProxyProtocol.socks5)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    FormRow(label: "业务验证目标",
                            help: "远端「已连接」结论基于对该目标的真实请求。留空使用默认目标 api.openai.com；填写你实际要用的服务地址（如 https://api.anthropic.com），验证通过才代表该业务可达。") {
                        TextField("https://（可选）", text: Binding(
                            get: { profile.probeTargetURL ?? "" },
                            set: { profile.probeTargetURL = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                    }
                    FormRow(label: "自动重连") {
                        Toggle(L10n.t("网络波动时自动恢复 SSH 连接"), isOn: $profile.reconnectEnabled)
                            .controlSize(.small)
                    }
                    FormRow(label: "启动后连接") {
                        Toggle(L10n.t("App 启动后，自动连接此服务器"), isOn: $profile.connectAtLaunch)
                            .controlSize(.small)
                    }
                }
            }

            InfoBlock(text: "注意：在共享 Linux 服务器上，即使只监听 127.0.0.1，同一服务器的其他本地用户进程也可能访问该端口。")

            if !validation.errors.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(validation.errors, id: \.self) { err in
                        Label(err, systemImage: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.red)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("校验错误：\(validation.errors.joined(separator: "；"))")
            }
            if !validation.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(validation.warnings, id: \.self) { warn in
                        Label(warn, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.orange)
                    }
                }
            }

            HStack {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text(L10n.t("删除配置"))
                }
                .controlSize(.large)
                .disabled(isNew)
                .confirmationDialog(
                    "确定删除服务器「\(profile.name)」？",
                    isPresented: $confirmDelete,
                    titleVisibility: .visible
                ) {
                    Button(L10n.t("删除（不可撤销）"), role: .destructive) { onDelete(profile) }
                    Button(L10n.t("取消"), role: .cancel) {}
                }

                Spacer()
                if isNew {
                    Button(L10n.t("放弃")) { onDiscard() }
                        .controlSize(.large)
                }
                Button {
                    onSave(profile)
                } label: {
                    Text(L10n.t("保存更改"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!validation.isValid)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var proxySummary: String {
        switch profile.connectionMode {
        case .automatic:
            if profile.proxySelectionMode == .manual, let ep = profile.manualEndpoint {
                return "自动：先验证手动入口 \(ep.displayEndpoint) · \(ep.protocol.displayName)，失败后使用动态 SOCKS5"
            }
            return "自动：优先实测本地入口；无可用入口时切换动态 SOCKS5"
        case .staticForward:
            if profile.proxySelectionMode == .manual, let ep = profile.manualEndpoint {
                return "静态转发 · \(ep.displayEndpoint) · \(ep.protocol.displayName)"
            }
            return "静态转发 · 连接前验证系统/环境代理入口"
        case .reverseDynamic:
            return "动态 SOCKS5 · 使用 Mac 网络栈 · 不需要本地代理端口"
        }
    }

    private func loopbackPortField(_ value: Binding<Int>, prompt: String) -> some View {
        HStack(spacing: 8) {
            MonoText(text: "127.0.0.1 :", size: 12)
                .foregroundStyle(Palette.muted)
            PortField(value: value, prompt: prompt)
            MiniBadge(text: "仅本机回环", tone: .green)
        }
    }

    private func browseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "选择私钥文件"
        panel.message = "仅保存文件路径引用，不读取密钥内容"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: "~/.ssh").expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            profile.identityFilePath = url.path
        }
    }
}

/// 端口输入框：数字、等宽。
@MainActor
struct PortField: View {
    @Binding var value: Int
    var prompt: String

    var body: some View {
        TextField(prompt, value: $value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
            .monospacedDigit()
    }
}
