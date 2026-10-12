import XCTest
@testable import ProxyBridge

/// LogStore 容量/前缀/导出格式 与 AppSettingsStore 损坏回退。
@MainActor
final class LogStoreTests: XCTestCase {

    func testCapacityClampKeepsNewest() {
        let store = LogStore()
        for i in 0..<(LogStore.capacity + 2) {
            store.append(raw: "event-\(i)", level: .info)
        }
        XCTAssertEqual(store.entries.count, LogStore.capacity, "环形缓冲必须收敛在容量上限")
        XCTAssertEqual(store.entries.first?.message, "event-2", "最旧的 2 条被裁剪")
        XCTAssertEqual(store.entries.last?.message, "event-\(LogStore.capacity + 1)", "最新一条保留")
    }

    func testSanitizationPreservesNormalText() {
        let store = LogStore()
        store.append(raw: "hello \u{1B}[31mworld\u{1B}[0m ~/.ssh/id_rsa", level: .info)
        let entry = store.entries.last
        XCTAssertTrue(entry?.message.hasPrefix("hello world ") == true, "日志保留普通文本")
        XCTAssertFalse(entry?.message.contains("\u{1B}") == true)
        XCTAssertFalse(entry?.message.contains(".ssh/") == true, "密钥路径入库即遮挡")
    }

    func testExportTextFormatAndRedaction() {
        let store = LogStore()
        store.append(raw: "connect 10.11.154.192 sunyun@10.11.154.192 ~/.ssh/id_ed25519", level: .success)
        let redacted = store.exportText(redacted: true)
        XCTAssertTrue(redacted.contains("[成功]"), "行格式为 HH:mm:ss [级别] 正文")
        XCTAssertFalse(redacted.contains("10.11.154.192"), "脱敏导出遮挡 IP")
        XCTAssertFalse(redacted.contains("sunyun@"), "脱敏导出遮挡 用户@主机")

        let raw = store.exportText(redacted: false)
        XCTAssertTrue(raw.contains("10.11.154.192"), "未脱敏导出保留原文（用户显式选择）")
    }

    func testAppSettingsCorruptionFallsBackAndReports() throws {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let store = AppSettingsStore(directoryURL: temp.url)
        XCTAssertEqual(store.load().remoteCheckIntervalSeconds, 60, "无文件 → 默认")
        XCTAssertFalse(store.lastLoadWasCorrupted, "首启不算损坏")

        try "{broken json".data(using: .utf8)!.write(to: temp.url.appendingPathComponent("settings.json"))
        let settings = store.load()
        XCTAssertEqual(settings.remoteCheckIntervalSeconds, 60, "损坏 → 回退默认")
        XCTAssertTrue(store.lastLoadWasCorrupted, "损坏必须可被调用方感知（写日志）")

        var custom = AppSettings.defaults()
        custom.redactLogsOnCopy = false
        custom.remoteCheckIntervalSeconds = 120
        try store.save(custom)
        let reloaded = store.load()
        XCTAssertFalse(reloaded.redactLogsOnCopy)
        XCTAssertEqual(reloaded.remoteCheckIntervalSeconds, 120)
        XCTAssertFalse(store.lastLoadWasCorrupted, "正常重载不算损坏")
    }
}
