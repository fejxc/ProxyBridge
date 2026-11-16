import XCTest
@testable import ProxyBridge

/// 复制命令模板：内容来自受控常量 + 数字端口，未验证时必须带提醒。
final class RemoteCommandTemplateTests: XCTestCase {

    func testHTTPCommandContent() {
        let text = RemoteCommandTemplate.exportCommands(remotePort: 7890, protocol: .http)
        XCTAssertTrue(text?.contains("export http_proxy=http://127.0.0.1:7890") == true)
        XCTAssertTrue(text?.contains("export https_proxy=http://127.0.0.1:7890") == true)
        XCTAssertTrue(text?.contains("https://api.openai.com/v1/models") == true)
        XCTAssertFalse(text?.contains("socks") == true, "HTTP 模板不得包含 socks 指令")
    }

    func testSOCKS5CommandContent() {
        let text = RemoteCommandTemplate.exportCommands(remotePort: 7891, protocol: .socks5)
        XCTAssertTrue(text?.contains("export ALL_PROXY=socks5h://127.0.0.1:7891") == true, "DNS 必须经代理解析（socks5h）")
        XCTAssertFalse(text?.contains("http_proxy") == true, "SOCKS 模板不得宣称 HTTP 可用")
    }

    func testReverseDynamicCommandsSeparateSOCKSFromHTTPCompatibility() {
        let socksOnly = RemoteCommandTemplate.dynamicClipboardText(
            socksPort: 17_890, httpPort: 7_890, includeHTTPAdapter: false,
            socksVerified: true, httpVerified: nil
        )
        XCTAssertTrue(socksOnly?.contains("--socks5-hostname 127.0.0.1:17890") == true)
        XCTAssertFalse(socksOnly?.contains("HTTP_PROXY") == true)
        XCTAssertFalse(socksOnly?.contains("http://127.0.0.1:17890") == true)

        let bPlus = RemoteCommandTemplate.dynamicClipboardText(
            socksPort: 17_890, httpPort: 7_890, includeHTTPAdapter: true,
            socksVerified: true, httpVerified: false
        )
        XCTAssertTrue(bPlus?.contains("export HTTP_PROXY=http://127.0.0.1:7890") == true)
        XCTAssertTrue(bPlus?.contains("export HTTPS_PROXY=http://127.0.0.1:7890") == true)
        XCTAssertTrue(bPlus?.contains("--proxy http://127.0.0.1:7890") == true)
        XCTAssertTrue(bPlus?.contains("--socks5-hostname 127.0.0.1:17890") == true)
        XCTAssertTrue(bPlus?.contains("HTTP 入口当前尚未通过 HTTP CONNECT 验证") == true)
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

    // MARK: 接入助手（1.11.0）

    /// 每套工具模板必须三段齐全：使用命令注入端口、验证命令、撤销命令；
    /// 持久化配置（git/npm/docker）没有撤销就是给用户埋雷。
    func testToolPresetUseVerifyUndoSections() {
        let expectations: [RemoteCommandTemplate.ToolPreset: (use: String, undo: String)] = [
            .git: ("git config --global http.proxy http://127.0.0.1:7890",
                   "git config --global --unset http.proxy"),
            .npm: ("npm config set proxy http://127.0.0.1:7890",
                   "npm config delete proxy"),
            .pip: ("export PIP_PROXY=http://127.0.0.1:7890",
                   "unset PIP_PROXY"),
            .docker: ("Environment=\"HTTP_PROXY=http://127.0.0.1:7890\"",
                      "sudo rm /etc/systemd/system/docker.service.d/http-proxy.conf"),
        ]
        for preset in RemoteCommandTemplate.ToolPreset.allCases {
            let text = RemoteCommandTemplate.toolPresetCommands(preset: preset, httpProxyPort: 7890, remoteVerified: true)
            let expected = expectations[preset]!
            XCTAssertTrue(text?.contains(expected.use) == true, "\(preset) 使用命令应注入端口")
            XCTAssertTrue(text?.contains(expected.undo) == true, "\(preset) 必须附带撤销命令")
            XCTAssertTrue(text?.contains("验证") == true, "\(preset) 必须附带验证步骤")
        }
    }

    func testToolPresetUnverifiedNotice() {
        let unverified = RemoteCommandTemplate.toolPresetCommands(preset: .git, httpProxyPort: 7890, remoteVerified: nil)
        XCTAssertTrue(unverified?.contains("尚未验证") == true, "未验证时必须提醒（与 clipboardText 同一语义）")
        let ok = RemoteCommandTemplate.toolPresetCommands(preset: .git, httpProxyPort: 7890, remoteVerified: true)
        XCTAssertFalse(ok?.contains("尚未验证") == true)
    }

    func testToolPresetInvalidPortReturnsNil() {
        XCTAssertNil(RemoteCommandTemplate.toolPresetCommands(preset: .git, httpProxyPort: 0, remoteVerified: true))
        XCTAssertNil(RemoteCommandTemplate.toolPresetCommands(preset: .docker, httpProxyPort: 65_536, remoteVerified: nil))
    }

    /// Docker 模板动 daemon 属高危操作：必须声明 sudo 与影响面，且 NO_PROXY 保住本机回环。
    func testDockerTemplateDeclaresSudoAndNoProxy() {
        let text = RemoteCommandTemplate.toolPresetCommands(preset: .docker, httpProxyPort: 7890, remoteVerified: true) ?? ""
        XCTAssertTrue(text.contains("sudo"))
        XCTAssertTrue(text.contains("影响整台服务器"))
        XCTAssertTrue(text.contains("NO_PROXY=localhost,127.0.0.1"))
        // printf 的 \n 是 shell 转义（两个字面字符），Swift 里必须是 \\n
        XCTAssertTrue(text.contains("[Service]\\nEnvironment="))
    }
}
