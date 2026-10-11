import SwiftUI

/// 「连接日志」Tab：时间 + 级别 + 消息，可按级别/服务器筛选，复制脱敏日志。
struct LogsView: View {
    @Environment(AppViewModel.self) private var model

    @State private var levelFilter: LogLevel?
    @State private var profileFilter: UUID?

    private var filtered: [LogEntry] {
        model.logStore.entries.filter { entry in
            if let levelFilter, entry.level != levelFilter { return false }
            if let profileFilter, entry.profileId != profileFilter { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Picker("级别", selection: $levelFilter) {
                    Text("全部级别").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(LogLevel?.some(level))
                    }
                }
                .frame(width: 130)

                Picker("服务器", selection: $profileFilter) {
                    Text("全部服务器").tag(UUID?.none)
                    ForEach(model.profiles) { p in
                        Text(p.name).tag(UUID?.some(p.id))
                    }
                }
                .frame(width: 160)

                Spacer()

                Button {
                    model.copyLogsToPasteboard()
                } label: {
                    Label("复制脱敏日志", systemImage: "doc.on.doc")
                }
                .help(model.settings.redactLogsOnCopy ? "复制时遮挡 IP / 用户@主机 / 密钥路径 / 凭据" : "当前设置：复制时不脱敏（包含主机与用户名）")

                Button {
                    model.logStore.removeAll()
                } label: {
                    Label("清空", systemImage: "trash")
                }
            }

            SectionCard(title: filtered.isEmpty ? "暂无匹配日志" : "最近活动（最多保留 \(LogStore.capacity) 条）") {
                if model.isDemoMode {
                    DemoModeBanner()
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { entry in
                        logRow(entry)
                    }
                }
                .background(Palette.surface)
            }

            InfoBlock(text: "日志入库前已过滤 ANSI 控制字符并遮挡密钥路径与凭据；复制时默认同时遮挡内网 IP 与 用户@主机。SSH stderr 不会被当作富文本解释执行。")
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(timeString(entry.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.muted.opacity(0.8))
            Text(entry.message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Text(entry.level.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(levelColor(entry.level))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.border.opacity(0.5))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info: return Palette.muted
        case .success: return Palette.green
        case .warning: return Palette.orange
        case .error: return Palette.red
        }
    }
}
