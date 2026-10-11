import XCTest
@testable import ProxyBridge

/// 端点解析优先级（U05）：手动指定 > 已验证自动候选 > 未发现。
final class EndpointResolverTests: XCTestCase {

    private func profile(mode: ProxySelectionMode = .automatic,
                         manual: LocalProxyEndpoint? = nil,
                         preferred: ProxyProtocol = .http) -> ServerProfile {
        ServerProfile(
            name: "t", host: "h.example.com", sshPort: 22, username: "u",
            remotePort: 7890, proxySelectionMode: mode,
            manualEndpoint: manual, preferredProtocol: preferred
        )
    }

    private var detectedState: ProxyDetectionState {
        var state = ProxyDetectionState()
        state.candidates = [
            ProxyCandidate(
                endpoint: LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP),
                capability: .verified
            ),
            ProxyCandidate(
                endpoint: LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .socks5, origin: .systemSOCKS),
                capability: .verified
            ),
        ]
        return state
    }

    func testManualOverridesAutoDetection() {
        let manual = LocalProxyEndpoint(host: "127.0.0.1", port: 1080, protocol: .socks5, origin: .manual)
        let resolved = EndpointResolver.resolve(profile: profile(mode: .manual, manual: manual), detection: detectedState)
        XCTAssertEqual(resolved, .manual(manual), "手动指定优先（U05）")
    }

    func testManualModeWithoutEndpointIsExplicitNone() {
        let resolved = EndpointResolver.resolve(profile: profile(mode: .manual, manual: nil), detection: detectedState)
        guard case .none(let reason) = resolved else {
            return XCTFail("应为 none，实际 \(resolved)")
        }
        XCTAssertTrue(reason.contains("手动"))
    }

    func testAutoPicksVerifiedEndpoint() {
        let resolved = EndpointResolver.resolve(profile: profile(), detection: detectedState)
        guard case .auto(let ep) = resolved else {
            return XCTFail("应为 auto，实际 \(resolved)")
        }
        XCTAssertEqual(ep.port, 7897)
        XCTAssertEqual(ep.protocol, .http, "默认首选 HTTP")
    }

    func testAutoRespectsPreferredProtocol() {
        let resolved = EndpointResolver.resolve(
            profile: profile(preferred: .socks5),
            detection: detectedState
        )
        guard case .auto(let ep) = resolved else {
            return XCTFail("应为 auto，实际 \(resolved)")
        }
        XCTAssertEqual(ep.protocol, .socks5)
    }

    func testAutoWithOnlyUnverifiedCandidatesIsNone() {
        var state = detectedState
        state.candidates = state.candidates.map { ProxyCandidate(endpoint: $0.endpoint, capability: .untested) }
        let resolved = EndpointResolver.resolve(profile: profile(), detection: state)
        guard case .none(let reason) = resolved else {
            return XCTFail("未验证候选不得被采用，实际 \(resolved)")
        }
        XCTAssertTrue(reason.contains("验证"))
    }

    func testNoCandidatesExplainsNotFound() {
        let resolved = EndpointResolver.resolve(profile: profile(), detection: ProxyDetectionState())
        guard case .none(let reason) = resolved else {
            return XCTFail("应为 none，实际 \(resolved)")
        }
        XCTAssertTrue(reason.contains("未发现"))
    }

    func testDescribeStrings() {
        let manual = LocalProxyEndpoint(host: "127.0.0.1", port: 1080, protocol: .socks5, origin: .manual)
        XCTAssertTrue(EndpointResolver.describe(.manual(manual), preferred: .http).contains("手动指定"))
        XCTAssertTrue(EndpointResolver.describe(.manual(manual), preferred: .http).contains("SOCKS5"))
        if case .auto(let ep) = EndpointResolver.resolve(profile: profile(), detection: detectedState) {
            XCTAssertTrue(EndpointResolver.describe(.auto(ep), preferred: .http).contains("自动检测"))
        }
        if case .none(let reason) = EndpointResolver.resolve(profile: profile(), detection: ProxyDetectionState()) {
            XCTAssertEqual(EndpointResolver.describe(.none(reason: reason), preferred: .http), reason)
        }
    }
}
