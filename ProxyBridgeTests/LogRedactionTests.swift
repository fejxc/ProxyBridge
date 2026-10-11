import XCTest
@testable import ProxyBridge

/// U17：日志脱敏 —— 不泄露凭据、密钥路径；过滤 ANSI 控制字符。
final class LogRedactionTests: XCTestCase {

    // MARK: ANSI / 控制字符过滤

    func testCSIEscapeSequencesAreStripped() {
        XCTAssertEqual(LogRedaction.sanitize("\u{1B}[31mRED\u{1B}[0m text"), "RED text")
        XCTAssertEqual(LogRedaction.sanitize("\u{1B}[1;31;42mbold\u{1B}[m"), "bold")
    }

    func testOSCEscapeSequencesAreStripped() {
        XCTAssertEqual(LogRedaction.sanitize("before\u{1B}]0;window title\u{07}after"), "beforeafter")
        XCTAssertEqual(LogRedaction.sanitize("x\u{1B}]2;t\u{1B}\\y"), "xy", "ST 形式（ESC \\）也要清除")
    }

    func testControlCharactersRemovedButNewlineAndTabKept() {
        XCTAssertEqual(LogRedaction.sanitize("a\rb\nc\td\u{7}e"), "ab\nc\td" + "e", "CR/BEL 删除，\\n\\t 保留")
        let sanitized = LogRedaction.sanitize("line1\nline2")
        XCTAssertTrue(sanitized.contains("\n"))
    }

    func testLoneEscapeDropped() {
        XCTAssertEqual(LogRedaction.sanitize("keep\u{1B}drop-next-char?ok"), "keepdrop-next-char?ok".replacingOccurrences(of: "\u{1B}", with: ""),
                       "孤立 ESC 及其转义处理不得残留 ESC")
        XCTAssertFalse(LogRedaction.sanitize("a\u{1B}Eb").contains("\u{1B}"))
    }

    func testOverlongMessagesAreTruncated() {
        let long = String(repeating: "a", count: LogRedaction.maxMessageLength + 500)
        let out = LogRedaction.sanitize(long)
        XCTAssertTrue(out.hasSuffix("…(截断)"))
        XCTAssertLessThanOrEqual(out.count, LogRedaction.maxMessageLength + 10)
    }

    // MARK: 敏感内容遮挡

    func testKeyPathsMasked() {
        let out = LogRedaction.redact("identity file /Users/alice/.ssh/id_ed25519 missing", options: .keyPaths)
        XCTAssertFalse(out.contains(".ssh/id_ed25519"))
        XCTAssertTrue(out.contains("[密钥路径]"))
        let out2 = LogRedaction.redact("cannot read ~/.ssh/id_rsa", options: .keyPaths)
        XCTAssertTrue(out2.contains("[密钥路径]"))
    }

    func testUserAtHostMasked() {
        let out = LogRedaction.redact("Connecting to sunyun@10.11.154.192 failed", options: .userHost)
        XCTAssertTrue(out.contains("[用户@主机]"))
        XCTAssertFalse(out.contains("sunyun@"))
    }

    func testIPMasked() {
        let out = LogRedaction.redact("host 192.168.1.100 unreachable", options: .ipAddresses)
        XCTAssertTrue(out.contains("[IP]"))
        XCTAssertFalse(out.contains("192.168.1.100"))
        // 版本号不应被误伤
        let v = LogRedaction.redact("OpenSSH_9.6p1", options: .ipAddresses)
        XCTAssertTrue(v.contains("OpenSSH_9.6p1"), "非 IP 形态（单点）不应被遮挡")
    }

    func testTokensMasked() {
        XCTAssertEqual(LogRedaction.redact("Bearer abcdef1234567890", options: .tokens), "Bearer [凭据]")
        XCTAssertEqual(LogRedaction.redact("token deadbeefdeadbeef", options: .tokens), "token [凭据]")
        let pub = LogRedaction.redact("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyGoesHere", options: .tokens)
        XCTAssertTrue(pub.contains("[公钥内容]"), "公钥内容不落日志：\(pub)")
    }

    func testExportRedactsEverythingByDefault() {
        let raw = "user sunyun@10.11.154.192 key ~/.ssh/id_ed25519 Bearer abcdef123456"
        let out = LogRedaction.redact(raw, options: .export)
        XCTAssertFalse(out.contains("sunyun@10.11.154.192"))
        XCTAssertFalse(out.contains(".ssh/"))
        XCTAssertFalse(out.contains("abcdef123456"))
    }

    func testSanitizeForStorageMasksKeysAndTokensButKeepsReadability() {
        let stored = LogRedaction.sanitizeForStorage(
            "ssh -i /Users/bob/.ssh/id_ed25519 sunyun@10.11.154.192 Bearer abcdef1234567890 \u{1B}[31merr\u{1B}[0m"
        )
        XCTAssertFalse(stored.contains("\u{1B}"))
        XCTAssertFalse(stored.contains(".ssh/"))
        XCTAssertFalse(stored.contains("abcdef1234567890"))
        XCTAssertTrue(stored.contains("10.11.154.192"), "入库默认保留 IP 便于排障（导出时再遮挡）")
        XCTAssertTrue(stored.contains("err"))
    }
}
