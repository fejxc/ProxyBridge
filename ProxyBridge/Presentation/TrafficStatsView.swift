import SwiftUI

@MainActor
struct TrafficStatsView: View {
    let session: TrafficSessionModel
    let connected: Bool
    @State private var expanded = false
    private let uploadColor = Color(nsColor: .systemBlue)
    private let downloadColor = Color(nsColor: .systemGreen)
    /// 仅静态转发模式渲染（动态 SOCKS5 无诚实数据源，面板不显示流量区块）。
    init(session: TrafficSessionModel, connected: Bool) {
        self.session = session
        self.connected = connected
    }
    private var value: TrafficSnapshot { session.snapshot }
    private var live: Bool { connected && value.isRunning }

    var body: some View {
        statistics
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                direction(title: L10n.t("上传"), symbol: "arrow.up", rate: value.uploadRate, bytes: value.uploadBytes, color: uploadColor)
                direction(title: L10n.t("下载"), symbol: "arrow.down", rate: value.downloadRate, bytes: value.downloadBytes, color: downloadColor)
            }
            DisclosureGroup(L10n.t("流量详情"), isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if value.samples.isEmpty {
                        Text(L10n.t("建立连接后显示最近 60 秒速率")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 90)
                    } else {
                        Canvas { context, size in
                            // session 是 @Observable 类，此闭包在绘制期才重新读取快照，
                            // 与外层 isEmpty 判断之间存在窗口；不能假设 samples 仍非空。
                            let points = value.samples
                            guard let newest = points.last else { return }
                            let maximum = max(1, points.flatMap { [$0.upload, $0.download] }.max() ?? 1)
                            for (upload, color) in [(true, uploadColor), (false, downloadColor)] {
                                var path = Path()
                                for (index, sample) in points.enumerated() {
                                    let age = newest.time.timeIntervalSince(sample.time)
                                    let x = size.width * CGFloat(max(0, min(1, 1 - age / 60)))
                                    let rate = upload ? sample.upload : sample.download
                                    let point = CGPoint(x: x, y: 1 + (size.height - 2) * (1 - CGFloat(rate / maximum)))
                                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                                }
                                context.stroke(path, with: .color(color), lineWidth: 1.5)
                            }
                        }
                        .frame(height: 90)
                        .accessibilityLabel(L10n.t("最近 60 秒实际上传和下载速率曲线"))
                        HStack {
                            Text(L10n.t("↑ 上传")).foregroundStyle(uploadColor)
                            Text(L10n.t("↓ 下载")).foregroundStyle(downloadColor)
                            Spacer(); Text(L10n.t("最近 60 秒")).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text(L10n.t("本次连接总流量"))
                        Spacer()
                        Text(value.sessionID == nil ? "—" : TrafficFormatting.total(value.uploadBytes + value.downloadBytes)).monospacedDigit()
                    }
                    if let port = value.relayPort {
                        Text("Relay 127.0.0.1:\(String(port)) · \(String(value.activeConnections))" + L10n.t(" 个 TCP 连接"))
                            .foregroundStyle(.secondary)
                    }
                    Text(L10n.t("统计 Relay 业务字节，含代理验证请求，不含 SSH 开销或其他网卡流量。"))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func direction(title: String, symbol: String, rate: Double, bytes: UInt64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title + L10n.t("速率"), systemImage: symbol).foregroundStyle(color).font(.caption)
            Text(live ? TrafficFormatting.rate(rate) : "—")
                .font(.system(size: 17, weight: .semibold)).monospacedDigit()
            Text(L10n.t("累计") + title + L10n.t("：") + (value.sessionID == nil ? "—" : TrafficFormatting.total(bytes)))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
