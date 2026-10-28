import XCTest
@testable import ProxyBridge

/// 诊断包：markdown 装配与磁盘日志尾段读取（脱敏边界）。
final class DiagnosticsReportTests: XCTestCase {

    private func makeContent(
        servers: [DiagnosticsReport.ServerInfo] = [DiagnosticsReport.ServerInfo(name: "hz", mode: "自动（推荐）", status: "已连接")],
        activeSummary: String? = "3/3 项已验证 · 刚刚验证",
        sessionLogs: String = "",
        diskTail: String? = nil
    ) -> DiagnosticsReport.Content {
        DiagnosticsReport.Content(
            appVersion: "1.8.1 (23)",
            systemVersion: "macOS Version 14.1 (Build 23B74)",
            servers: servers,
            activeSummary: activeSummary,
            sessionLogs: sessionLogs,
            diskLogPathLabel: diskTail == nil ? nil : "~/Library/Logs/ProxyBridge/app.log",
            diskLogTail: diskTail,
            diskLogTruncated: false
        )
    }

    func testMarkdownContainsEnvironmentServersAndSummary() {
        let report = DiagnosticsReport.markdown(makeContent(), now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(report.contains("应用版本：1.8.1 (23)"), "环境段必须含应用版本")
        XCTAssertTrue(report.contains("macOS Version 14.1"), "环境段必须含系统版本")
        XCTAssertTrue(report.contains("「hz」") && report.contains("自动（推荐）"), "服务器段必须含名称与模式")
        XCTAssertTrue(report.contains("3/3 项已验证"), "健康摘要必须入报告")
        XCTAssertTrue(report.contains("github.com/fejxc/ProxyBridge/issues"), "报告必须指向 issue 入口")
    }

    func testMarkdownEmbedsSessionLogsAndDiskTail() {
        let report = DiagnosticsReport.markdown(
            makeContent(sessionLogs: "12:00:00 [信息] 启动", diskTail: "disk-tail-line")
        )
        XCTAssertTrue(report.contains("12:00:00 [信息] 启动"))
        XCTAssertTrue(report.contains("disk-tail-line"))
        XCTAssertTrue(report.contains("app.log"), "磁盘日志段落必须标注来源路径")
    }

    func testMarkdownEmptyStates() {
        let report = DiagnosticsReport.markdown(
            makeContent(servers: [], activeSummary: nil, sessionLogs: "", diskTail: nil)
        )
        XCTAssertTrue(report.contains("尚未配置服务器"))
        XCTAssertTrue(report.contains("（本次会话无日志）"))
        XCTAssertFalse(report.contains("## 磁盘日志末段"), "无磁盘日志路径时不出现该段")
    }

    func testDiskLogTailReadsLastLinesAndRedacts() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString).log")
        var body = ""
        for i in 0..<200 { body += "line-\(i) token=abcdefgh12345678\n" }
        body += "connect 10.11.154.192\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = DiagnosticsReport.diskLogTail(url: url, maxLines: 50)
        XCTAssertNotNil(tail, "应能读到磁盘日志尾段")
        guard let tail else { return }
        let lines = tail.text.split(separator: "\n")
        XCTAssertEqual(lines.count, 50, "行数上限收敛")
        XCTAssertEqual(lines.last, "connect [IP]", "末行保留且 IP 被遮挡")
        XCTAssertTrue(tail.text.contains("token=[凭据]"), "凭据形态必须被遮挡")
        XCTAssertFalse(tail.text.contains("10.11.154.192"), "原始 IP 不得出机")
        XCTAssertTrue(tail.text.contains("line-199"), "必须保留文件末尾")
        XCTAssertFalse(tail.text.contains("line-100\n"), "超出上限的更早行被裁剪")
        XCTAssertFalse(tail.truncated, "未触字节上限时不得标注截断")
    }

    func testDiskLogTailMarksTruncation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString).log")
        try String(repeating: "line-0123456789\n", count: 100)
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = DiagnosticsReport.diskLogTail(url: url, maxLines: 1_000, maxBytes: 64)
        XCTAssertNotNil(tail)
        guard let tail else { return }
        XCTAssertTrue(tail.truncated, "超过字节上限必须如实标注截断")
        XCTAssertFalse(tail.text.contains("line-0123456789\nline"), "截断起点丢弃残行")
    }

    func testDiskLogTailMissingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-missing-\(UUID().uuidString).log")
        XCTAssertNil(DiagnosticsReport.diskLogTail(url: url))
    }
}
