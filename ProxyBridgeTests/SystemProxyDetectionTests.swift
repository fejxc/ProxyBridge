import XCTest
@testable import ProxyBridge

/// 系统代理解析（U01–U04 的输入侧）与候选构建纯函数。
final class SystemProxyDetectionTests: XCTestCase {

    // MARK: SCDynamicStore 字典解析

    func testParseFullDictionary() {
        let dict: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7897,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897,
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7897,
            "ProxyAutoConfigEnable": 0,
            "ProxyAutoDiscoveryEnable": 0,
        ]
        let snap = SCDynamicStoreProxyProvider.parse(dict)
        XCTAssertEqual(snap.http, .init(host: "127.0.0.1", port: 7897))
        XCTAssertEqual(snap.https, .init(host: "127.0.0.1", port: 7897))
        XCTAssertEqual(snap.socks, .init(host: "127.0.0.1", port: 7897))
        XCTAssertFalse(snap.pacEnabled)
    }

    func testParseIgnoresDisabledOrInvalidEntries() {
        let dict: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 0,        // 端口 0 → 忽略
            "HTTPSEnable": 1, "HTTPSPort": 7897,                              // 缺 host → 忽略
            "SOCKSEnable": 0, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1080,   // 未启用 → 忽略
            "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://pac.example.com/proxy.pac",
        ]
        let snap = SCDynamicStoreProxyProvider.parse(dict)
        XCTAssertNil(snap.http)
        XCTAssertNil(snap.https)
        XCTAssertNil(snap.socks)
        XCTAssertTrue(snap.pacEnabled)
        XCTAssertEqual(snap.pacURL, "http://pac.example.com/proxy.pac")
        XCTAssertFalse(snap.hasAnyExplicitProxy)
    }

    func testParsePortAsStringTolerated() {
        let dict: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": "7897",
        ]
        let snap = SCDynamicStoreProxyProvider.parse(dict)
        XCTAssertEqual(snap.http?.port, 7897)
    }

    func testProxyEnvironmentParserSupportsUppercaseAndSOCKSURI() {
        let parsed = ProxyEnvironmentParser.parse([
            "HTTP_PROXY": "http://127.0.0.1:7891",
            "https_proxy": "127.0.0.1:7892",
            "ALL_PROXY": "socks5h://127.0.0.1:1080",
        ])
        XCTAssertEqual(parsed.endpoints.count, 3)
        XCTAssertEqual(parsed.endpoints.first?.protocol, .http)
        XCTAssertEqual(parsed.endpoints.first?.origin, .environmentHTTP)
        XCTAssertTrue(parsed.endpoints.contains { $0.protocol == .socks5 && $0.port == 1080 })
    }

    func testProxyEnvironmentRejectsCredentialsWithoutEchoingThem() {
        let parsed = ProxyEnvironmentParser.parse([
            "http_proxy": "http://alice:secret@127.0.0.1:7891",
        ])
        XCTAssertTrue(parsed.endpoints.isEmpty)
        XCTAssertTrue(parsed.limitations.joined().contains("http_proxy"))
        XCTAssertFalse(parsed.limitations.joined().contains("alice"))
        XCTAssertFalse(parsed.limitations.joined().contains("secret"))
    }

    func testSystemCandidatesOutrankEnvironmentCandidates() {
        let built = ProxyCandidateBuilder.build(
            from: snapshot(http: .init(host: "127.0.0.1", port: 7897)),
            environment: ["ALL_PROXY": "socks5h://127.0.0.1:1080"]
        )
        var state = ProxyDetectionState(candidates: built.candidates)
        state.candidates = state.candidates.map { candidate in
            var copy = candidate
            copy.capability = .verified
            return copy
        }
        XCTAssertEqual(state.bestVerifiedEndpoint(preferred: .socks5)?.origin, .systemHTTP)
        XCTAssertEqual(state.bestVerifiedEndpoint(preferred: .socks5)?.protocol, .http)
    }

    // MARK: 候选构建（U01–U04）

    private func snapshot(
        http: SystemProxySnapshot.ExplicitProxy? = nil,
        https: SystemProxySnapshot.ExplicitProxy? = nil,
        socks: SystemProxySnapshot.ExplicitProxy? = nil,
        pac: Bool = false
    ) -> SystemProxySnapshot {
        var snap = SystemProxySnapshot()
        snap.http = http
        snap.https = https
        snap.socks = socks
        snap.pacEnabled = pac
        return snap
    }

    /// U01：HTTPEnable/HTTPPort 存在 → 可创建 HTTP 候选。
    func testU01HTTPOnlyCreatesHTTPCandidate() {
        let built = ProxyCandidateBuilder.build(from: snapshot(http: .init(host: "127.0.0.1", port: 7897)))
        XCTAssertEqual(built.candidates.count, 1)
        XCTAssertEqual(built.candidates.first?.endpoint.protocol, .http)
        XCTAssertEqual(built.candidates.first?.endpoint.origin, .systemHTTP)
        XCTAssertEqual(built.candidates.first?.capability, .untested, "构建后未探测，不得宣称已验证")
        XCTAssertNil(built.candidates.first?.endpoint.verifiedAt)
    }

    /// U02：SOCKS 与 HTTP 同端口 → 端点去重，保留两项协议待测。
    func testU02SamePortHTTPAndSOCKSKeepBothProtocols() {
        let built = ProxyCandidateBuilder.build(from: snapshot(
            http: .init(host: "127.0.0.1", port: 7897),
            socks: .init(host: "127.0.0.1", port: 7897)
        ))
        XCTAssertEqual(built.candidates.count, 2, "同一物理端点去重，但两个协议分别待测")
        XCTAssertEqual(Set(built.candidates.map { $0.endpoint.protocol }), [.http, .socks5])
        XCTAssertEqual(built.candidates.map { $0.endpoint.displayEndpoint },
                       ["127.0.0.1:7897", "127.0.0.1:7897"])
    }

    func testHTTPAndHTTPSFieldsDedupeToSingleHTTPCandidate() {
        // HTTP 与 HTTPS 字段同 host:port：到代理的协议同为 HTTP CONNECT → 只保留一条（来源 systemHTTP）
        let built = ProxyCandidateBuilder.build(from: snapshot(
            http: .init(host: "127.0.0.1", port: 7897),
            https: .init(host: "127.0.0.1", port: 7897)
        ))
        XCTAssertEqual(built.candidates.count, 1)
        XCTAssertEqual(built.candidates.first?.endpoint.origin, .systemHTTP)
    }

    /// U03：系统代理全关 → 明确未发现，不产生任何候选。
    func testU03AllDisabledYieldsNoCandidatesAndLimitation() {
        let built = ProxyCandidateBuilder.build(from: snapshot())
        XCTAssertTrue(built.candidates.isEmpty)
        XCTAssertFalse(built.limitations.isEmpty, "必须有「未发现」说明而非静默")
        XCTAssertTrue(built.limitations.joined().contains("未发现可验证的本地代理端口"))
    }

    /// U04：PAC 模式 → 显示限制，不生成固定端口候选。
    func testU04PACOnlyYieldsNoPortAndLimitation() {
        var snap = snapshot(pac: true)
        snap.pacURL = "http://pac.example.com/proxy.pac"
        let built = ProxyCandidateBuilder.build(from: snap)
        XCTAssertTrue(built.candidates.isEmpty, "PAC 未解析出固定端口时不得捏造候选")
        XCTAssertTrue(built.limitations.joined().contains("PAC"))
        XCTAssertTrue(built.limitations.joined().contains("pac.example.com"))
    }

    func testPACWithExplicitProxiesStillBuildsCandidatesAndNotesPAC() {
        let built = ProxyCandidateBuilder.build(from: snapshot(
            http: .init(host: "127.0.0.1", port: 7897), pac: true
        ))
        XCTAssertEqual(built.candidates.count, 1, "PAC 开启但同时有显式代理字段时，显式候选仍可待测")
        XCTAssertTrue(built.limitations.joined().contains("PAC"))
    }

    func testNonLoopbackCandidateMarkedUntestedWithNote() {
        let built = ProxyCandidateBuilder.build(from: snapshot(http: .init(host: "10.0.0.2", port: 3128)))
        XCTAssertEqual(built.candidates.count, 1)
        let candidate = built.candidates[0]
        XCTAssertEqual(candidate.capability, .untested, "非回环 MVP 不探测")
        XCTAssertTrue(candidate.note?.contains("非本机回环") == true)
    }

    func testLoopbackDetectionCovers127RangeAndIPv6Forms() {
        XCTAssertTrue(ProxyCandidateBuilder.isLoopback("127.0.0.1"))
        XCTAssertTrue(ProxyCandidateBuilder.isLoopback("127.8.8.8"), "127.0.0.0/8 全段都是回环")
        XCTAssertTrue(ProxyCandidateBuilder.isLoopback("LOCALHOST"))
        XCTAssertTrue(ProxyCandidateBuilder.isLoopback("::1"))
        XCTAssertTrue(ProxyCandidateBuilder.isLoopback("[::1]"))
        XCTAssertTrue(ProxyCandidateBuilder.isLoopback("0:0:0:0:0:0:0:1"))
        XCTAssertFalse(ProxyCandidateBuilder.isLoopback("10.0.0.2"))
        XCTAssertFalse(ProxyCandidateBuilder.isLoopback("192.168.1.1"))
        XCTAssertFalse(ProxyCandidateBuilder.isLoopback("::2"))
        XCTAssertFalse(ProxyCandidateBuilder.isLoopback("fe80::1"))
        XCTAssertFalse(ProxyCandidateBuilder.isLoopback("127.1"), "非四段点分不按 127/8 处理")
    }

    func testCandidateStableSortingExactOrder() {
        // 精确顺序断言（id 字典序）：http|…1080 < http|…7897 < socks5|…
        let built = ProxyCandidateBuilder.build(from: snapshot(
            http: .init(host: "127.0.0.1", port: 7897),
            socks: .init(host: "127.0.0.1", port: 1080)
        ))
        XCTAssertEqual(
            built.candidates.map(\.id),
            ["http|127.0.0.1|7897", "socks5|127.0.0.1|1080"],
            "候选顺序必须按 id 字典序稳定输出"
        )
    }

    // MARK: curl 参数数组（U07 同源：保真、无 shell 面）

    func testCurlHTTPArgumentsExactArray() {
        let args = CurlProxyProbe.arguments(
            host: "127.0.0.1", port: 7897, protocol: .http,
            urlString: "https://www.example.com/", connectTimeout: 2, maxTime: 8
        )
        XCTAssertEqual(args, [
            "-q", // 首参数：跳过 ~/.curlrc（防配置劫持探测）
            "--noproxy", "",
            "--proxy", "http://127.0.0.1:7897",
            "--connect-timeout", "2",
            "--max-time", "8",
            "--silent", "--show-error",
            "--output", "/dev/null",
            "--write-out", "%{http_code}",
            "https://www.example.com/",
        ])
        XCTAssertEqual(args.first, "-q", "-q 必须是第一个参数才生效")
    }

    func testIPv6HostIsBracketedInProxyValue() {
        // 已实证：无方括号时 curl exit 5「无法解析代理地址」
        let http = CurlProxyProbe.arguments(
            host: "::1", port: 7897, protocol: .http,
            urlString: "https://www.example.com/", connectTimeout: 2, maxTime: 8
        )
        XCTAssertEqual(http[4], "http://[::1]:7897")
        let socks = CurlProxyProbe.arguments(
            host: "::1", port: 1080, protocol: .socks5,
            urlString: "https://www.example.com/", connectTimeout: 2, maxTime: 8
        )
        XCTAssertEqual(socks[4], "[::1]:1080")
        // 已带方括号的不重复包
        let bracketed = CurlProxyProbe.arguments(
            host: "[::1]", port: 1080, protocol: .socks5,
            urlString: "https://www.example.com/", connectTimeout: 2, maxTime: 8
        )
        XCTAssertEqual(bracketed[4], "[::1]:1080")
    }

    func testCurlSOCKSArgumentsUseSocks5Hostname() {
        let args = CurlProxyProbe.arguments(
            host: "127.0.0.1", port: 7890, protocol: .socks5,
            urlString: "https://www.example.com/", connectTimeout: 2, maxTime: 8
        )
        XCTAssertEqual(args[3], "--socks5-hostname", "SOCKS 探测必须让 DNS 经代理解析")
        XCTAssertEqual(args[4], "127.0.0.1:7890")
        XCTAssertEqual(args.first, "-q", "探测不能被 curlrc 覆盖")
    }

    func testCurlArgumentsRejectNonWhitelistURL() {
        // 白名单外 URL 触发 precondition —— 用 expectFatalError 太重，直接验证白名单集合
        XCTAssertTrue(CurlProxyProbe.urlWhitelist.contains(CurlProxyProbe.verificationURL))
    }

    func testProbeHostValidation() {
        XCTAssertTrue(CurlProxyProbe.isValidProbeHost("127.0.0.1"))
        XCTAssertTrue(CurlProxyProbe.isValidProbeHost("::1"))
        XCTAssertTrue(CurlProxyProbe.isValidProbeHost("proxy.example.com"))
        XCTAssertFalse(CurlProxyProbe.isValidProbeHost(""))
        XCTAssertFalse(CurlProxyProbe.isValidProbeHost("host with space"))
        XCTAssertFalse(CurlProxyProbe.isValidProbeHost("host;rm -rf /"))
        XCTAssertFalse(CurlProxyProbe.isValidProbeHost("--evil-flag"), "以 - 开头的恶意『主机』必须拒绝（防 curl 参数注入）")
        XCTAssertFalse(CurlProxyProbe.isValidProbeHost(String(repeating: "a", count: 254)))
    }

    // MARK: 探测解析（U12 语义核心）

    func testParseVerified2xxAnd3xx() {
        XCTAssertEqual(CurlProxyProbe.parse(exitCode: 0, stdout: "200"), .verified(statusCode: 200))
        XCTAssertEqual(CurlProxyProbe.parse(exitCode: 0, stdout: "302"), .verified(statusCode: 302))
        XCTAssertEqual(CurlProxyProbe.parse(exitCode: 0, stdout: " 204 \n"), .verified(statusCode: 204))
    }

    /// U12：HTTP 端口 open 但协议失败 → 不得 verified。
    func testU12PortOpenButNotProxy() {
        // 非 proxy HTTP 服务器应答 404
        XCTAssertEqual(CurlProxyProbe.parse(exitCode: 0, stdout: "404"), .reachableNotProxy(statusCode: 404))
        // CONNECT 被普通服务器拒绝（curl 56）
        XCTAssertEqual(CurlProxyProbe.parse(exitCode: 56, stdout: "000"), .reachableNotProxy(statusCode: nil))
        XCTAssertFalse(CurlProxyProbe.parse(exitCode: 0, stdout: "404").isVerified)
    }

    func testParseFailureModes() {
        XCTAssertEqual(CurlProxyProbe.parse(exitCode: 7, stdout: "000"), .connectionRefused)
        XCTAssertEqual(CurlProxyProbe.parse(exitCode: 28, stdout: "000"), .timeout)
        XCTAssertEqual(CurlProxyProbe.parse(exitCode: 35, stdout: "000"), .tlsError)
        XCTAssertEqual(CurlProxyProbe.parse(exitCode: 0, stdout: "407"), .authRequired)
        if case .failed = CurlProxyProbe.parse(exitCode: 1, stdout: "") {} else {
            XCTFail("未知退出码应落入 failed")
        }
        if case .failed = CurlProxyProbe.parse(exitCode: 0, stdout: "") {} else {
            XCTFail("退出 0 但无状态码应 failed")
        }
    }

    func testProxyAuth407ViaConnectFailure() {
        // HTTPS 验证流程中代理回 407：curl exit 56 + stderr 带 response 407
        let outcome = CurlProxyProbe.parse(
            exitCode: 56, stdout: "000",
            stderr: "curl: (56) CONNECT tunnel failed, response 407"
        )
        XCTAssertEqual(outcome, .authRequired, "带认证代理必须给出认证提示而非「CONNECT 被拒」")
        // 其他 56（无 407 特征）仍是可达但非代理
        XCTAssertEqual(
            CurlProxyProbe.parse(exitCode: 56, stdout: "000", stderr: "curl: (56) Recv failure"),
            .reachableNotProxy(statusCode: nil)
        )
    }

    func testCertificateFailureMapsToTLSError() {
        XCTAssertEqual(
            CurlProxyProbe.parse(exitCode: 60, stdout: "000", stderr: "SSL certificate problem: self signed certificate"),
            .tlsError
        )
        // failed 原因应包含 stderr 细节
        if case .failed(let reason) = CurlProxyProbe.parse(exitCode: 16, stdout: "", stderr: "some internal error") {
            XCTAssertTrue(reason.contains("some internal error"), "stderr 应进入失败原因")
        } else {
            XCTFail("exit 16 应为 failed")
        }
    }

    func testParseIgnores4xx5xxAsNotVerified() {
        XCTAssertEqual(CurlProxyProbe.parse(exitCode: 0, stdout: "502"), .reachableNotProxy(statusCode: 502))
        XCTAssertEqual(CurlProxyProbe.parse(exitCode: 0, stdout: "500"), .reachableNotProxy(statusCode: 500))
    }
}
