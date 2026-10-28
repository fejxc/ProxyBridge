import SwiftUI

/// 「连接日志」Tab：按时间/级别/服务器筛选 + 关键词搜索；
/// 错误/警告行可展开查看完整内容与修复建议（长消息默认折叠）。
@MainActor
struct LogsView: View {
    @Environment(AppViewModel.self) private var model

    @State private var levelFilter: LogLevel?
    @State private var profileFilter: UUID?
    @State private var timeScope: TimeScope = .all
    @State private var searchText = ""
    /// 展开查看完整内容 / 修复建议的行（会话级视图状态，不持久化）。
    @State private var expandedIDs: Set<UUID> = []

    enum TimeScope: String, CaseIterable, Identifiable {
        case all, lastHour, last24Hours
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L10n.t("全部时间")
            case .lastHour: return L10n.t("近 1 小时")
            case .last24Hours: return L10n.t("近 24 小时")
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
            if !searchText.isEmpty, !entry.message.localizedCaseInsensitiveContains(searchText) { return false }
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

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                    TextField(L10n.t("搜索日志…"), text: $searchText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Palette.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.t("清除搜索"))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.softFill, in: RoundedRectangle(cornerRadius: 6))
                .frame(width: 190)

                Spacer()

                Button {
                    model.copyLogsToPasteboard()
                } label: {
                    Label(model.settings.redactLogsOnCopy ? L10n.t("复制脱敏日志") : L10n.t("复制未脱敏日志"),
                          systemImage: "doc.on.doc")
                }
                .help(model.settings.redactLogsOnCopy
                      ? "复制时遮挡 IP / 用户@主机 / 密钥路径 / 凭据"
                      : "当前设置：复制时不脱敏（包含主机与用户名），可在通用设置中开启")

                Button {
                    model.revealLogFile()
                } label: {
                    Label(L10n.t("定位日志文件"), systemImage: "folder.magnifier")
                }
                .help("在 Finder 中打开 ~/Library/Logs/ProxyBridge/app.log；完整历史记录在磁盘上，重启不丢失")

                Button {
                    model.exportDiagnosticsBundle()
                } label: {
                    Label(L10n.t("导出诊断包"), systemImage: "stethoscope")
                }
                .help("生成脱敏诊断文件（环境、连接状态、会话与磁盘日志末段），可直接附到 GitHub issue")

                Button(role: .destructive) {
                    model.logStore.removeAll()
                } label: {
                    Label(L10n.t("清空"), systemImage: "trash")
                }
            }

            SectionCard(title: filtered.isEmpty
                        ? L10n.t("暂无匹配日志")
                        : String(format: L10n.t("最近活动（最多保留 %d 条）"), LogStore.capacity)) {
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
        let expanded = expandedIDs.contains(entry.id)
        let hint = entry.level == .error || entry.level == .warning
            ? LogDiagnostics.hint(for: entry.message)
            : nil
        let collapsible = LogDiagnostics.needsCollapse(entry.message) || hint != nil
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.muted.opacity(0.8))
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.message)
                    .font(.callout)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if expanded, let hint {
                    hintBlock(hint, tone: levelColor(entry.level))
                }
            }
            Spacer(minLength: 0)
            Text(entry.level.displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(levelColor(entry.level))
            if collapsible {
                Button {
                    if expanded { expandedIDs.remove(entry.id) } else { expandedIDs.insert(entry.id) }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? L10n.t("收起详情") : L10n.t("查看详情与修复建议"))
            }
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

    /// 结论先行：一句标题 + 下一步动作，再谈细节。
    private func hintBlock(_ hint: LogDiagnostics.Hint, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(hint.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tone)
                Text(hint.suggestion)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.softFill.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hint.title)，\(hint.suggestion)")
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
