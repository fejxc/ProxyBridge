import SwiftUI

/// 「本地代理」Tab：自动/手动分段、检测结果、协议能力、限制说明（原型 tab-proxy）。
@MainActor
struct ProxySettingsView: View {
    @Environment(AppViewModel.self) private var model

    @State private var manualHost = "127.0.0.1"
    @State private var manualPort = 7897
    @State private var manualProtocol: ProxyProtocol = .http
    @State private var manualErrors: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.currentProfile?.connectionMode == .reverseDynamic {
                InfoBlock(text: "当前使用动态 SOCKS5：不需要 Mac 本地 HTTP/SOCKS 端口。此页的本地代理入口仅在切换到静态或自动模式时使用。")
            }
            GroupBox(L10n.t("代理来源")) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(L10n.t("模式"), selection: modeBinding) {
                        Text(L10n.t("自动检测")).tag(ProxySelectionMode.automatic)
                        Text(L10n.t("手动指定")).tag(ProxySelectionMode.manual)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)

                    if model.currentProfile?.proxySelectionMode == .manual {
                        manualCard
                    } else {
                        autoCard
                    }
                }
            }

            if !model.detection.limitations.isEmpty {
                GroupBox(L10n.t("限制与说明")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.detection.limitations, id: \.self) { limit in
                            Label(limit, systemImage: "exclamationmark.circle")
                                .font(.subheadline)
                                .foregroundStyle(Palette.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            InfoBlock(text: "读取 macOS 系统代理与当前 App 可见的 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY，对回环候选逐协议经 curl 实测 https://api.openai.com/v1/models。未认证响应 HTTP 401 也表示请求已到达 API。PAC 与凭据型环境变量不会被当作固定入口；动态 SOCKS5 可处理没有本地监听端口的 Network Extension 模式。")
        }
        .onAppear { loadManualFields() }
        .onChange(of: model.currentProfileId) { _, _ in
            loadManualFields()
            manualErrors = []
        }
    }

    /// 从当前 profile 的手动端点回填表单（无则保持默认初值）。
    private func loadManualFields() {
        if let ep = model.currentProfile?.manualEndpoint {
            manualHost = ep.host
            manualPort = ep.port
            manualProtocol = ep.protocol
        }
    }

    private var modeBinding: Binding<ProxySelectionMode> {
        Binding(
            get: { model.currentProfile?.proxySelectionMode ?? .automatic },
            set: { model.setProxySelectionMode($0) }
        )
    }

    // MARK: 自动检测卡

    private var autoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.detection.isScanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在检测本地代理…"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.softFill)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            } else if model.detection.candidates.isEmpty {
                emptyDetectionCard
            } else {
                detectedCard
            }

            HStack {
                Spacer()
                Button {
                    model.redetectProxy()
                } label: {
                    Label(L10n.t("重新检测"), systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.regular)
            }
        }
    }

    private var emptyDetectionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Palette.orange.opacity(0.15))
                Image(systemName: "questionmark")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(Palette.orange)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("未发现可用的本地代理候选"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(L10n.t("未发现可验证的本地代理端口。可手动指定入口；若代理使用 TUN/Network Extension，也可以使用动态 SOCKS5。"))
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var detectedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Palette.green.opacity(0.15))
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(Palette.green)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("检测到本地代理端点"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text(scannedAtText)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                MetaLine(text: "系统检测")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(model.detection.candidates) { candidate in
                    candidateCard(candidate)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    /// 时间格式化器创建开销高，进程内缓存复用（同 LogsView 的做法）。
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var scannedAtText: String {
        let formatter = Self.timeFormatter
        guard let date = model.detection.lastScanAt else { return "尚未完成检测" }
        return "最近检测 \(formatter.string(from: date)) · 各协议验证结果见下方"
    }

    private func candidateCard(_ candidate: ProxyCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(candidate.endpoint.protocol.displayName + L10n.t(" 代理"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                capabilityBadge(candidate.capability)
            }
            MonoText(text: candidate.endpoint.displayEndpoint, size: 11.5)
                .foregroundStyle(Palette.muted)
            Text(L10n.t("来源：") + candidate.endpoint.origin.displayName)
                .font(.footnote)
                .foregroundStyle(Palette.muted.opacity(0.9))
            if let note = candidate.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func capabilityBadge(_ capability: ProxyCandidate.Capability) -> some View {
        switch capability {
        case .verified:
            MetaLine(text: "已验证", tone: .green)
        case .reachable:
            MetaLine(text: "端口可达 · 不可用作代理", tone: .orange)
        case .failed:
            MetaLine(text: "验证失败", tone: .red)
        case .untested:
            MetaLine(text: "未测试")
        }
    }

    // MARK: 手动卡

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 外层已是 GroupBox 分组，表单行不再套第二层容器（避免双重装箱）
            VStack(spacing: 14) {
                FormRow(label: "代理地址", help: "MVP 仅支持本机回环地址") {
                    TextField("127.0.0.1", text: $manualHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .autocorrectionDisabled()
                }
                FormRow(label: "代理端口") {
                    PortField(value: $manualPort, prompt: "端口")
                }
                FormRow(label: "协议", help: "以连接时的实测验证为准") {
                    Picker(L10n.t("协议"), selection: $manualProtocol) {
                    Text("HTTP").tag(ProxyProtocol.http)
                    Text("SOCKS5").tag(ProxyProtocol.socks5)
                    Text("Mixed").tag(ProxyProtocol.mixed)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }

            if !manualErrors.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(manualErrors, id: \.self) { err in
                        Label(err, systemImage: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Palette.red)
                    }
                }
            }

            HStack {
                Text(L10n.t("手动指定的优先级高于自动检测结果；连接前仍会实测验证。"))
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button {
                    manualErrors = model.applyManualEndpoint(
                        host: manualHost, port: manualPort, protocol: manualProtocol
                    )
                } label: {
                    Text(L10n.t("应用手动代理"))
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
