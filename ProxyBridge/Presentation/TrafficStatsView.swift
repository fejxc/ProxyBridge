import SwiftUI

@MainActor
struct TrafficStatsView: View {
    let session: TrafficSessionModel
    let connected: Bool
    @State private var expanded = false
    private let uploadColor = Color(red: 0.28, green: 0.48, blue: 0.70)
    private let downloadColor = Color(red: 0.25, green: 0.56, blue: 0.42)
    init(session: TrafficSessionModel, connected: Bool, initiallyExpanded: Bool = false) {
        self.session = session; self.connected = connected
        _expanded = State(initialValue: initiallyExpanded)
    }
    private var value: TrafficSnapshot { session.snapshot }
    private var live: Bool { connected && value.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                direction(title: "上传", symbol: "arrow.up", rate: value.uploadRate, bytes: value.uploadBytes, color: uploadColor)
                direction(title: "下载", symbol: "arrow.down", rate: value.downloadRate, bytes: value.downloadBytes, color: downloadColor)
            }
            DisclosureGroup("流量详情", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if value.samples.isEmpty {
                        Text("建立连接后显示最近 60 秒速率").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 90)
                    } else {
                        Canvas { context, size in
                            let points = value.samples
                            let maximum = max(1, points.flatMap { [$0.upload, $0.download] }.max() ?? 1)
                            for (upload, color) in [(true, uploadColor), (false, downloadColor)] {
                                var path = Path()
                                for (index, sample) in points.enumerated() {
                                    let age = points.last!.time.timeIntervalSince(sample.time)
                                    let x = size.width * CGFloat(max(0, min(1, 1 - age / 60)))
                                    let rate = upload ? sample.upload : sample.download
                                    let point = CGPoint(x: x, y: 1 + (size.height - 2) * (1 - CGFloat(rate / maximum)))
                                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                                }
                                context.stroke(path, with: .color(color), lineWidth: 1.5)
                            }
                        }
                        .frame(height: 90)
                        .accessibilityLabel("最近 60 秒实际上传和下载速率曲线")
                        HStack {
                            Text("↑ 上传").foregroundStyle(uploadColor)
                            Text("↓ 下载").foregroundStyle(downloadColor)
                            Spacer(); Text("最近 60 秒").foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("本次连接总流量")
                        Spacer()
                        Text(value.sessionID == nil ? "—" : TrafficFormatting.total(value.uploadBytes + value.downloadBytes)).monospacedDigit()
                    }
                    if let port = value.relayPort {
                        Text("Relay 127.0.0.1:\(String(port)) · \(String(value.activeConnections)) 个 TCP 连接")
                            .foregroundStyle(.secondary)
                    }
                    Text("统计 Relay 业务字节，含代理验证请求，不含 SSH 开销或其他网卡流量。")
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
            Label(title + "速率", systemImage: symbol).foregroundStyle(color).font(.caption)
            Text(live ? TrafficFormatting.rate(rate) : "—")
                .font(.system(size: 17, weight: .semibold)).monospacedDigit()
            Text("累计\(title)：" + (value.sessionID == nil ? "—" : TrafficFormatting.total(bytes)))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
