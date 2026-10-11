import XCTest
@testable import ProxyBridge

/// 复制命令模板：内容来自受控常量 + 数字端口，未验证时必须带提醒。
final class RemoteCommandTemplateTests: XCTestCase {

    func testHTTPCommandContent() {
        let text = RemoteCommandTemplate.exportCommands(remotePort: 7890, protocol: .http)
        XCTAssertTrue(text.contains("export http_proxy=http://127.0.0.1:7890"))
        XCTAssertTrue(text.contains("export https_proxy=http://127.0.0.1:7890"))
        XCTAssertTrue(text.contains("curl -I https://www.example.com"))
        XCTAssertFalse(text.contains("socks"), "HTTP 模板不得包含 socks 指令")
    }

    func testSOCKS5CommandContent() {
        let text = RemoteCommandTemplate.exportCommands(remotePort: 7891, protocol: .socks5)
        XCTAssertTrue(text.contains("export ALL_PROXY=socks5h://127.0.0.1:7891"), "DNS 必须经代理解析（socks5h）")
        XCTAssertFalse(text.contains("http_proxy"), "SOCKS 模板不得宣称 HTTP 可用")
    }

    func testClipboardAddsNoticeWhenUnverified() {
        let unverified = RemoteCommandTemplate.clipboardText(remotePort: 7890, protocol: .http, remoteVerified: nil)
        XCTAssertTrue(unverified.contains("尚未验证"), "remoteVerified == nil 时必须提醒")
        let failed = RemoteCommandTemplate.clipboardText(remotePort: 7890, protocol: .http, remoteVerified: false)
        XCTAssertTrue(failed.contains("尚未验证"), "验证失败同样提醒")
        let ok = RemoteCommandTemplate.clipboardText(remotePort: 7890, protocol: .http, remoteVerified: true)
        XCTAssertFalse(ok.contains("尚未验证"), "已验证时不附加告警")
    }

    func testPortIsEmbeddedNumerically() {
        let text = RemoteCommandTemplate.exportCommands(remotePort: 12345, protocol: .http)
        XCTAssertTrue(text.contains(":12345"))
    }
}
