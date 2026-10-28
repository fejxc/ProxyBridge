import XCTest
@testable import ProxyBridge

/// B2 上游代理认证：报文字节格式、curl 配置转义、模型兼容与校验。
final class UpstreamAuthTests: XCTestCase {

    // MARK: - SOCKS5 RFC 1929 / HTTP Basic 报文构造

    func testSocks5Greeting() {
        XCTAssertEqual(Array(UpstreamAuthWire.socks5Greeting(credentials: nil)), [0x05, 0x01, 0x00],
                       "无凭据仅提供 NO-AUTH（回环惯例不变）")
        XCTAssertEqual(Array(UpstreamAuthWire.socks5Greeting(credentials: ProxyCredentials(username: "u", password: "p"))),
                       [0x05, 0x02, 0x00, 0x02],
                       "有凭据同时提供 NO-AUTH 与 USERPASS（服务器任选）")
    }

    func testSocks5UserPassRequestFormat() {
        let request = UpstreamAuthWire.socks5UserPassRequest(username: "user", password: "p@ss")
        XCTAssertNotNil(request)
        XCTAssertEqual(Array(request!), [0x01, 0x04] + Array("user".utf8) + [0x04] + Array("p@ss".utf8),
                       "VER=1 ULEN UNAME PLEN PASSWD")
    }

    func testSocks5UserPassRequestLimits() {
        XCTAssertNil(UpstreamAuthWire.socks5UserPassRequest(username: "", password: "p"),
                     "空用户名拒绝（认证没有意义）")
        XCTAssertNil(UpstreamAuthWire.socks5UserPassRequest(username: String(repeating: "u", count: 256), password: "p"),
                     "用户名超 255 字节拒绝")
        XCTAssertNil(UpstreamAuthWire.socks5UserPassRequest(username: "u", password: String(repeating: "p", count: 256)),
                     "密码超 255 字节拒绝")
        XCTAssertNotNil(UpstreamAuthWire.socks5UserPassRequest(username: String(repeating: "u", count: 255), password: ""),
                        "255 字节恰好可表达；空密码允许（有些代理只验用户名）")
    }

    func testProxyAuthorizationValue() {
        let value = UpstreamAuthWire.proxyAuthorizationValue(username: "user", password: "pass")
        XCTAssertEqual(value, "Basic dXNlcjpwYXNz", "base64(\"user:pass\")")
        XCTAssertEqual(value, "Basic " + Data("user:pass".utf8).base64EncodedString())
    }

    // MARK: - curl 凭据配置文件

    func testCredentialConfigEscaping() {
        let contents = CurlProxyProbe.credentialConfigContents(
            ProxyCredentials(username: "user", password: "p\"a\\ss")
        )
        XCTAssertEqual(contents, "proxy-user = \"user:p\\\"a\\\\ss\"\n",
                       "引号与反斜杠按 curl 配置语法转义")
    }

    func testCredentialConfigRejectsLineBreaks() {
        XCTAssertNil(CurlProxyProbe.credentialConfigContents(
            ProxyCredentials(username: "u", password: "a\nb")
        ), "换行密码无法在单行配置中表达，如实失败")
        XCTAssertNil(CurlProxyProbe.credentialConfigContents(
            ProxyCredentials(username: "u", password: "a\rb")
        ))
    }

    // MARK: - 模型兼容与校验

    private func decodeProfile(_ json: String) throws -> ServerProfile {
        try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
    }

    func testOldProfileJSONDecodesWithoutUpstreamAuth() throws {
        let json = """
        {"id":"DEADBEEF-1111-2222-3333-444455556666","name":"srv","host":"example.com",
         "sshPort":22,"username":"root","authMode":"agent","remotePort":7890}
        """
        let profile = try decodeProfile(json)
        XCTAssertNil(profile.upstreamAuthUsername, "旧文件缺失该键时按 nil 兼容")
    }

    func testUpstreamUsernameNormalization() throws {
        let json = """
        {"id":"DEADBEEF-1111-2222-3333-444455556666","name":"srv","host":"example.com",
         "sshPort":22,"username":"root","authMode":"agent","remotePort":7890,
         "upstreamAuthUsername":"  user  "}
        """
        XCTAssertEqual(try decodeProfile(json).upstreamAuthUsername, "user", "解码时 trim")
        let profile = ServerProfile(name: "s", host: "example.com", sshPort: 22, username: "root", remotePort: 7890, upstreamAuthUsername: "   ")
        XCTAssertNil(profile.upstreamAuthUsername, "纯空白归一化为 nil（不使用认证）")
    }

    func testValidationRejectsInvalidUpstreamUsername() {
        func profile(username: String?) -> ServerProfile {
            ServerProfile(name: "s", host: "example.com", sshPort: 22, username: "root", remotePort: 7890, upstreamAuthUsername: username)
        }
        XCTAssertTrue(ServerProfileRule.validate(profile(username: "corp-user")).isValid)
        XCTAssertFalse(ServerProfileRule.validate(profile(username: "us:er")).isValid, "冒号会被 curl 当作用户名分隔")
        XCTAssertFalse(ServerProfileRule.validate(profile(username: "us er")).isValid)
        XCTAssertFalse(ServerProfileRule.validate(profile(username: String(repeating: "u", count: 129))).isValid)
    }
}
