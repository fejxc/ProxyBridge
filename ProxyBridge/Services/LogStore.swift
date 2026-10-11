import Foundation
import OSLog
import Observation

enum LogLevel: String, Codable, Sendable, CaseIterable {
    case info
    case success
    case warning
    case error

    var displayName: String {
        switch self {
        case .info: return "信息"
        case .success: return "成功"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }
}

/// 一条应用日志。message 在写入前已经过 LogRedaction.sanitizeForStorage。
struct LogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let profileId: UUID?
    let level: LogLevel
    let message: String
}

/// 固定容量的环形日志缓冲 + OSLog 镜像。
/// UI 只观察 AppViewModel 暴露的快照数组；本类在主线程使用。
@MainActor
@Observable
final class LogStore {
    static let capacity = 500

    private(set) var entries: [LogEntry] = []
    private let osLog = Logger(subsystem: "dev.sunyun.ProxyBridge", category: "app")

    /// 记录一条日志。raw 内容会先脱敏再入库。
    /// `demoPrefix`：阶段 A 演示事件以「演示」开头，明确与真实行为区分。
    @discardableResult
    func append(
        raw message: String,
        level: LogLevel,
        profileId: UUID? = nil,
        isDemoEvent: Bool = false
    ) -> LogEntry {
        let sanitized = LogRedaction.sanitizeForStorage(message)
        let text = isDemoEvent ? "[演示] " + sanitized : sanitized
        let entry = LogEntry(
            id: UUID(),
            timestamp: Date(),
            profileId: profileId,
            level: level,
            message: text
        )
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        switch level {
        case .info: osLog.info("\(text, privacy: .public)")
        case .success: osLog.notice("\(text, privacy: .public)")
        case .warning: osLog.warning("\(text, privacy: .public)")
        case .error: osLog.error("\(text, privacy: .public)")
        }
        return entry
    }

    func removeAll() {
        entries.removeAll()
    }

    /// 复制用文本（默认脱敏选项由调用方传入）。
    func exportText(redacted: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries
            .map { entry in
                let body = redacted
                    ? LogRedaction.redact(entry.message, options: .all)
                    : entry.message
                return "\(formatter.string(from: entry.timestamp)) [\(entry.level.displayName)] \(body)"
            }
            .joined(separator: "\n")
    }
}
