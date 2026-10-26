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
        // 损坏文件必须保底留存（改名隔离），否则下一次 save 会覆盖掉人工排查现场
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: temp.url.path)) ?? []
        XCTAssertTrue(leftovers.contains { $0.hasPrefix("settings.corrupt-") },
                      "损坏文件应被改名隔离，实际目录内容：\(leftovers)")

        var custom = AppSettings.defaults()
        custom.redactLogsOnCopy = false
        custom.remoteCheckIntervalSeconds = 120
        try store.save(custom)
        let reloaded = store.load()
        XCTAssertFalse(reloaded.redactLogsOnCopy)
        XCTAssertEqual(reloaded.remoteCheckIntervalSeconds, 120)
        XCTAssertFalse(store.lastLoadWasCorrupted, "正常重载不算损坏")
    }

    /// 落盘副本：live 构造写入文件、包含脱敏内容、超限轮转；内存构造不触碰磁盘。
    func testPersistentLogWritesAndRotates() throws {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let store = LogStore.live(directoryURL: temp.url)
        store.append(raw: "连接 10.11.154.192 失败 sunyun@10.11.154.192 Bearer abcdef1234567890", level: .warning)
        let file = temp.url.appendingPathComponent("app.log")
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(content.contains("10.11.154.192"), "IP 保留供排障")
        XCTAssertFalse(content.contains("abcdef1234567890"), "凭据必须脱敏")
        XCTAssertTrue(content.contains("ProxyBridge 启动"), "启动分隔行应落盘")

        store.fileSizeLimit = 64 // 极小阈值触发轮转
        store.append(raw: "再写一条触发轮转", level: .info)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("app.log.1").path),
                      "超限后归档为 app.log.1")
        let rotated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(rotated.contains("再写一条触发轮转"), "轮转后新内容写入新文件")

        // 内存构造不落盘（测试/冒烟默认，不污染用户目录）
        let memoryOnly = LogStore()
        memoryOnly.append(raw: "仅内存", level: .info)
        XCTAssertNil(memoryOnly.fileURL)
    }

    // MARK: LogDiagnostics（修复建议纯函数）

    func testHintMatchesAuthFailureCaseInsensitively() {
        pinChineseForTesting()
        let hint = LogDiagnostics.hint(for: "SSH 连接失败: permission denied (publickey,password)")
        XCTAssertEqual(hint?.title, "SSH 认证失败")
        XCTAssertTrue(hint?.suggestion.contains("核对用户名") ?? false)

        let zh = LogDiagnostics.hint(for: "认证失败，已自动清除已存密码")
        XCTAssertEqual(zh?.title, "SSH 认证失败")
    }

    func testHintForHostKeyChangePortConflictTimeoutAndRefused() {
        pinChineseForTesting()
        XCTAssertEqual(LogDiagnostics.hint(for: "REMOTE HOST IDENTIFICATION HAS CHANGED")?.title, "主机指纹变化")
        XCTAssertEqual(LogDiagnostics.hint(for: "bind 127.0.0.1:17891: Address already in use")?.title, "远端端口冲突")
        XCTAssertEqual(LogDiagnostics.hint(for: "Connection timed out")?.title, "连接超时")
        XCTAssertEqual(
            LogDiagnostics.hint(for: "ssh: connect to host 127.0.0.1 port 1: Connection refused")?.title,
            "SSH 端口拒连"
        )
    }

    func testHintNilForPlainMessages() {
        pinChineseForTesting()
        XCTAssertNil(LogDiagnostics.hint(for: "ProxyBridge 启动"))
        XCTAssertNil(LogDiagnostics.hint(for: "已保存服务器「测试机」"))
        XCTAssertNil(LogDiagnostics.hint(for: ""), "空消息不给建议")
    }

    func testNeedsCollapseRules() {
        XCTAssertTrue(LogDiagnostics.needsCollapse("第一行\n第二行"), "多行原始输出默认折叠")
        XCTAssertTrue(LogDiagnostics.needsCollapse(String(repeating: "长", count: 121)))
        XCTAssertFalse(LogDiagnostics.needsCollapse("短消息"))
    }
}
