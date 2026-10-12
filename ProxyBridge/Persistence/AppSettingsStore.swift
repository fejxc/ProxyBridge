import Foundation

/// 通用设置（通用设置 Tab 持久化的全部字段）。
struct AppSettings: Codable, Equatable {
    /// 用户请求的登录启动偏好；界面以 SMAppService 实际状态为准。
    var launchAtLoginRequested: Bool
    var showNotifications: Bool
    /// 远端健康检查周期（秒）。默认 60，避免过度探测。
    var remoteCheckIntervalSeconds: Int
    /// 本地轻量检查周期（秒）。默认 30。
    var localCheckIntervalSeconds: Int
    /// 复制日志时默认脱敏。
    var redactLogsOnCopy: Bool

    static let allowedRemoteIntervals: [Int] = [30, 60, 120, 300]
    static let allowedLocalIntervals: [Int] = [15, 30, 60]

    static func defaults() -> AppSettings {
        AppSettings(
            launchAtLoginRequested: false,
            showNotifications: true,
            remoteCheckIntervalSeconds: 60,
            localCheckIntervalSeconds: 30,
            redactLogsOnCopy: true
        )
    }

    var sanitized: AppSettings {
        var s = self
        if !Self.allowedRemoteIntervals.contains(s.remoteCheckIntervalSeconds) {
            s.remoteCheckIntervalSeconds = 60
        }
        if !Self.allowedLocalIntervals.contains(s.localCheckIntervalSeconds) {
            s.localCheckIntervalSeconds = 30
        }
        return s
    }
}

/// AppSettings 的 JSON 持久化（settings.json，原子写）。
final class AppSettingsStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.sunyun.ProxyBridge.settings")
    /// 最近一次 load 是否遇到「文件存在但无法解析」（区别于首启无文件）。
    private(set) var lastLoadWasCorrupted = false

    init(directoryURL: URL? = nil) {
        let dir = directoryURL ?? ProfileRepository.defaultDirectory()
        self.fileURL = dir.appendingPathComponent("settings.json")
    }

    func load() -> AppSettings {
        queue.sync {
            lastLoadWasCorrupted = false
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return .defaults()
            }
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
            else {
                // 损坏：回退默认值但如实上报（调用方写日志），不静默吞掉
                lastLoadWasCorrupted = true
                return .defaults()
            }
            return decoded.sanitized
        }
    }

    func save(_ settings: AppSettings) throws {
        try queue.sync {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(settings)
            try data.write(to: fileURL, options: [.atomic])
        }
    }
}
