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

/// 固定容量的环形日志缓冲 + OSLog 镜像 + 磁盘审计副本。
/// UI 只观察 AppViewModel 暴露的快照数组；本类在主线程使用。
/// 磁盘文件（~/Library/Logs/ProxyBridge/app.log）是排障用的持久记录：
/// 内存环形缓冲重启即丢，网络波动类问题往往要靠事后看日志定位。
@MainActor
@Observable
final class LogStore {
    static let capacity = 500
    /// 单文件上限，超过后轮转为 app.log.1（保留一代，覆盖旧归档）。
    var fileSizeLimit: Int = 2 * 1024 * 1024
    /// 落盘文件位置（nil = 仅内存，测试注入目录后自动生效）。
    private(set) var fileURL: URL?
    private var fileHandle: FileHandle?

    private(set) var entries: [LogEntry] = []
    private let osLog = Logger(subsystem: "dev.sunyun.ProxyBridge", category: "app")

    /// 生产构造：内存环形 + 磁盘审计副本（默认 ~/Library/Logs/ProxyBridge/app.log）。
    static func live(directoryURL: URL? = nil) -> LogStore {
        LogStore(persistToDisk: true, directoryURL: directoryURL)
    }

    /// 仅内存（测试与冒烟默认：不触碰用户目录，行为与历史版本一致）。
    convenience init() {
        self.init(persistToDisk: false, directoryURL: nil)
    }

    private init(persistToDisk: Bool, directoryURL: URL?) {
        guard persistToDisk else { return }
        let dir = directoryURL ?? FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ProxyBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app.log")
        fileURL = url
        rotateIfNeeded()
        fileHandle = openHandle(at: url)
        try? fileHandle?.seekToEnd()
        append(raw: "—— ProxyBridge 启动（此后日志同步写入 \(url.path)）——", level: .info)
    }

    // 说明：LogStore 与 App 同生命周期，句柄由进程退出回收；
    // 轮转时在 rotateIfNeeded 内显式关闭重开。

    /// 记录一条日志。raw 内容会先脱敏再入库；同时追加到磁盘副本。
    @discardableResult
    func append(
        raw message: String,
        level: LogLevel,
        profileId: UUID? = nil
    ) -> LogEntry {
        let text = LogRedaction.sanitizeForStorage(message)
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
        writeToFile(entry)
        return entry
    }

    func removeAll() {
        entries.removeAll()
        // 磁盘副本是审计记录：UI 清空不影响文件
    }

    // MARK: - 磁盘副本

    private let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func writeToFile(_ entry: LogEntry) {
        if (fileHandle?.offsetInFile ?? 0) > UInt64(fileSizeLimit) {
            rotateIfNeeded()
        }
        guard let handle = fileHandle else { return }
        let line = "\(fileDateFormatter.string(from: entry.timestamp)) [\(entry.level.displayName)] \(entry.message)\n"
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// 打开追加句柄；文件不存在时先创建（FileHandle(forWritingTo:) 不建文件）。
    private func openHandle(at url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: url)
    }

    private func rotateIfNeeded() {
        guard let url = fileURL,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > fileSizeLimit else { return }
        fileHandle?.closeFile()
        fileHandle = nil
        let archived = url.deletingLastPathComponent().appendingPathComponent("app.log.1")
        try? FileManager.default.removeItem(at: archived)
        try? FileManager.default.moveItem(at: url, to: archived)
        fileHandle = openHandle(at: url)
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
