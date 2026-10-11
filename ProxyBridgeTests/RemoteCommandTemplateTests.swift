import XCTest
@testable import ProxyBridge

/// 复制命令模板：内容来自受控常量 + 数字端口，未验证时必须带提醒。
final class RemoteCommandTemplateTests: XCTestCase {

    func testHTTPCommandContent() {
        let text = RemoteCommandTemplate.exportCommands(remotePort: 7890, protocol: .http)
        XCTAssertTrue(text?.contains("export http_proxy=http://127.0.0.1:7890") == true)
        XCTAssertTrue(text?.contains("export https_proxy=http://127.0.0.1:7890") == true)
        XCTAssertTrue(text?.contains("curl -I https://www.example.com") == true)
        XCTAssertFalse(text?.contains("socks") == true, "HTTP 模板不得包含 socks 指令")
    }

    func testSOCKS5CommandContent() {
        let text = RemoteCommandTemplate.exportCommands(remotePort: 7891, protocol: .socks5)
        XCTAssertTrue(text?.contains("export ALL_PROXY=socks5h://127.0.0.1:7891") == true, "DNS 必须经代理解析（socks5h）")
        XCTAssertFalse(text?.contains("http_proxy") == true, "SOCKS 模板不得宣称 HTTP 可用")
    }

    func testClipboardAddsNoticeWhenUnverified() {
        let unverified = RemoteCommandTemplate.clipboardText(remotePort: 7890, protocol: .http, remoteVerified: nil)
        XCTAssertTrue(unverified?.contains("尚未验证") == true, "remoteVerified == nil 时必须提醒")
        let failed = RemoteCommandTemplate.clipboardText(remotePort: 7890, protocol: .http, remoteVerified: false)
        XCTAssertTrue(failed?.contains("尚未验证") == true, "验证失败同样提醒")
        let ok = RemoteCommandTemplate.clipboardText(remotePort: 7890, protocol: .http, remoteVerified: true)
        XCTAssertFalse(ok?.contains("尚未验证") == true, "已验证时不附加告警")
    }

    func testPortIsEmbeddedNumerically() {
        let text = RemoteCommandTemplate.exportCommands(remotePort: 12345, protocol: .http)
        XCTAssertTrue(text?.contains(":12345") == true)
    }

    func testInvalidPortReturnsNilNotCrash() {
        // 持久化脏数据防御：越界端口不得触发崩溃
        XCTAssertNil(RemoteCommandTemplate.exportCommands(remotePort: 0, protocol: .http))
        XCTAssertNil(RemoteCommandTemplate.exportCommands(remotePort: 65_536, protocol: .socks5))
        XCTAssertNil(RemoteCommandTemplate.clipboardText(remotePort: 99_999, protocol: .http, remoteVerified: true))
    }
}
