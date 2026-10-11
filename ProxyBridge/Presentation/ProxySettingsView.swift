import SwiftUI

/// 「本地代理」Tab：自动/手动分段、检测结果、协议能力、限制说明（原型 tab-proxy）。
struct ProxySettingsView: View {
    @Environment(AppViewModel.self) private var model

    @State private var manualHost = "127.0.0.1"
    @State private var manualPort = 7897
    @State private var manualProtocol: ProxyProtocol = .http
    @State private var manualErrors: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(title: "代理来源") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("模式", selection: modeBinding) {
                        Text("自动检测").tag(ProxySelectionMode.automatic)
                        Text("手动指定").tag(ProxySelectionMode.manual)
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
                SectionCard(title: "限制与说明") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.detection.limitations, id: \.self) { limit in
                            Label(limit, systemImage: "exclamationmark.circle")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            InfoBlock(text: "自动发现仅是第一步。真实版本必须通过代理协议实际发出请求确认有效（阶段 B 实现）；PAC、仅 TUN、需要认证的代理可能需要手动配置。检测结果仅来自当前这台 Mac，不会跨机器套用。")
        }
        .onAppear {
            if let ep = model.currentProfile?.manualEndpoint {
                manualHost = ep.host
                manualPort = ep.port
                manualProtocol = ep.protocol
            }
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
                    Text("正在检测本地代理…（演示）")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.green.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Palette.green.opacity(0.3), lineWidth: 1)
                )
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
                    Label("重新检测", systemImage: "arrow.triangle.2.circlepath")
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.orange)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("未发现本地系统代理候选")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("可手动指定端口；真实版本会读取系统设置并逐协议实测（阶段 B）。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
    }

    private var detectedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Palette.green.opacity(0.15))
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.green)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("检测到本地代理端点")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(scannedAtText)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                MiniBadge(text: "演示数据", tone: .orange)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(model.detection.candidates) { candidate in
                    candidateCard(candidate)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.green.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Palette.green.opacity(0.25), lineWidth: 1)
        )
    }

    private var scannedAtText: String {
        if let date = model.detection.lastScanAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return "最近检测 \(formatter.string(from: date)) · 127.0.0.1 · 阶段 A 演示值（未读取系统）"
        }
        return "阶段 A 演示值（未读取系统）"
    }

    private func candidateCard(_ candidate: ProxyCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(candidate.endpoint.protocol.displayName) 代理")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                capabilityBadge(candidate.capability)
            }
            MonoText(text: candidate.endpoint.displayEndpoint, size: 11.5)
                .foregroundStyle(Palette.muted)
            Text("来源：\(candidate.endpoint.origin.displayName)")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted.opacity(0.9))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func capabilityBadge(_ capability: ProxyCandidate.Capability) -> some View {
        switch capability {
        case .verified:
            MiniBadge(text: "已验证 · 演示", tone: .green)
        case .reachable:
            MiniBadge(text: "端口可达 · 未验证协议", tone: .orange)
        case .failed:
            MiniBadge(text: "协议验证失败", tone: .red)
        case .untested:
            MiniBadge(text: "未测试", tone: .gray)
        }
    }

    // MARK: 手动卡

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard(title: nil) {
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
                        Picker("协议", selection: $manualProtocol) {
                            Text("HTTP").tag(ProxyProtocol.http)
                            Text("SOCKS5").tag(ProxyProtocol.socks5)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                }
            }

            if !manualErrors.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(manualErrors, id: \.self) { err in
                        Label(err, systemImage: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.red)
                    }
                }
            }

            HStack {
                Text("手动指定的优先级高于自动检测结果；连接前仍会实测验证。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button {
                    manualErrors = model.applyManualEndpoint(
                        host: manualHost, port: manualPort, protocol: manualProtocol
                    )
                } label: {
                    Text("应用手动代理")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
