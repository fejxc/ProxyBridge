import SwiftUI

/// 「连接日志」Tab：按时间/级别/服务器筛选，复制（默认脱敏）日志。
@MainActor
struct LogsView: View {
    @Environment(AppViewModel.self) private var model

    @State private var levelFilter: LogLevel?
    @State private var profileFilter: UUID?
    @State private var timeScope: TimeScope = .all

    enum TimeScope: String, CaseIterable, Identifiable {
        case all, lastHour, last24Hours
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部时间"
            case .lastHour: return "近 1 小时"
            case .last24Hours: return "近 24 小时"
            }
        }
        var cutoff: Date? {
            switch self {
            case .all: return nil
            case .lastHour: return Date().addingTimeInterval(-3_600)
            case .last24Hours: return Date().addingTimeInterval(-86_400)
            }
        }
    }

    /// 时间格式化器创建开销高，进程内缓存复用。
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var filtered: [LogEntry] {
        model.logStore.entries.filter { entry in
            if let levelFilter, entry.level != levelFilter { return false }
            if let profileFilter, entry.profileId != profileFilter { return false }
            if let cutoff = timeScope.cutoff, entry.timestamp < cutoff { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Picker(L10n.t("时间"), selection: $timeScope) {
                    ForEach(TimeScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .frame(width: 110)

                Picker(L10n.t("级别"), selection: $levelFilter) {
                    Text(L10n.t("全部级别")).tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(LogLevel?.some(level))
                    }
                }
                .frame(width: 120)

                Picker(L10n.t("服务器"), selection: $profileFilter) {
                    Text(L10n.t("全部服务器")).tag(UUID?.none)
                    ForEach(model.profiles) { p in
                        Text(p.name).tag(UUID?.some(p.id))
                    }
                }
                .frame(width: 150)

                Spacer()

                Button {
                    model.copyLogsToPasteboard()
                } label: {
                    Label(model.settings.redactLogsOnCopy ? "复制脱敏日志" : "复制未脱敏日志",
                          systemImage: "doc.on.doc")
                }
                .help(model.settings.redactLogsOnCopy
                      ? "复制时遮挡 IP / 用户@主机 / 密钥路径 / 凭据"
                      : "当前设置：复制时不脱敏（包含主机与用户名），可在通用设置中开启")

                Button {
                    model.logStore.removeAll()
                } label: {
                    Label(L10n.t("清空"), systemImage: "trash")
                }
            }

            SectionCard(title: filtered.isEmpty ? "暂无匹配日志" : "最近活动（最多保留 \(LogStore.capacity) 条）") {
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
            Text(Self.timeFormatter.string(from: entry.timestamp))
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

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info: return Palette.muted
        case .success: return Palette.green
        case .warning: return Palette.orange
        case .error: return Palette.red
        }
    }
}
