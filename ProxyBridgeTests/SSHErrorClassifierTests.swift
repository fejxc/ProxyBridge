import XCTest
@testable import ProxyBridge

/// stderr/exitCode 分类（U09/U10）与远端探测解析。
final class SSHErrorClassifierTests: XCTestCase {

    // MARK: U09：Permission denied → authRequired 且停止无意义重连

    func testU09PermissionDeniedIsAuthRequired() {
        let c = SSHErrorClassifier.classify(
            exitCode: 255,
            stderr: "sunyun@10.11.154.192: Permission denied (publickey)."
        )
        guard case .authRequired(let detail) = c else {
            return XCTFail("应为 authRequired，实际 \(c)")
        }
        XCTAssertTrue(detail.contains("认证"))
    }

    func testHostKeyVerificationIsAuthRequired() {
        let c = SSHErrorClassifier.classify(
            exitCode: 255,
            stderr: "Host key verification failed."
        )
        guard case .authRequired(let detail) = c else {
            return XCTFail("应为 authRequired，实际 \(c)")
        }
        XCTAssertTrue(detail.contains("known_hosts") || detail.contains("指纹"))
    }

    // MARK: U10：remote port forwarding failed → error

    func testU10ForwardFailureIsError() {
        let c = SSHErrorClassifier.classify(
            exitCode: 255,
            stderr: "Warning: remote port forwarding failed for listen port 7890"
        )
        guard case .error(let detail) = c else {
            return XCTFail("应为 error，实际 \(c)")
        }
        XCTAssertTrue(detail.contains("端口") || detail.contains("转发"))
    }

    func testAdministrativelyProhibitedIsError() {
        let c = SSHErrorClassifier.classify(exitCode: 255, stderr: "channel: administratively prohibited")
        guard case .error = c else { return XCTFail("应为 error，实际 \(c)") }
    }

    func testNetworkFailuresAreError() {
        for stderr in [
            "ssh: connect to host 10.11.154.192 port 20064: Connection timed out",
            "ssh: Could not resolve hostname bad.example.com: Name or service not known",
            "ssh: connect to host 127.0.0.1 port 1: Connection refused",
            "ssh: connect to host 10.9.9.9 port 22: No route to host",
        ] {
            let c = SSHErrorClassifier.classify(exitCode: 255, stderr: stderr)
            guard case .error = c else { return XCTFail("「\(stderr)」应为 error，实际 \(c)") }
        }
    }

    func testAgentRelatedAuthFailures() {
        let tooMany = SSHErrorClassifier.classify(exitCode: 255, stderr: "Too many authentication failures")
        guard case .authRequired = tooMany else { return XCTFail("实际 \(tooMany)") }
        let none = SSHErrorClassifier.classify(exitCode: 255, stderr: "no supported authentication methods left to try")
        guard case .authRequired = none else { return XCTFail("实际 \(none)") }
    }

    func testUnknownFailureIsGeneric() {
        let c = SSHErrorClassifier.classify(exitCode: 74, stderr: "")
        guard case .genericFailure(let code) = c else { return XCTFail("实际 \(c)") }
        XCTAssertEqual(code, 74)
    }

    func testPhaseMapping() {
        let auth = SSHErrorClassifier.phaseAndDetail(for: .authRequired(detail: "x"))
        XCTAssertEqual(auth.phase, .authRequired)
        let err = SSHErrorClassifier.phaseAndDetail(for: .error(detail: "y"))
        XCTAssertEqual(err.phase, .error)
        let generic = SSHErrorClassifier.phaseAndDetail(for: .genericFailure(exitCode: 9))
        XCTAssertEqual(generic.phase, .error)
        XCTAssertTrue(generic.detail.contains("9"))
    }

    // MARK: 远端探测解析

    func testRemoteParseVerified() {
        XCTAssertEqual(
            SSHRemoteProbe.parse(exitCode: 0, stdout: "200", stderr: ""),
            .verified(statusCode: 200)
        )
        XCTAssertEqual(
            SSHRemoteProbe.parse(exitCode: 0, stdout: "204\n", stderr: ""),
            .verified(statusCode: 204)
        )
    }

    /// U11 语义：远端 curl 未安装 → unknown（不得显示「全部正常」）。
    func testRemoteParseCurlMissingIsUnknown() {
        let outcome = SSHRemoteProbe.parse(
            exitCode: 0,
            stdout: RemoteProbeCommand.noCurlMarker,
            stderr: ""
        )
        XCTAssertEqual(outcome, .remoteCurlMissing)
        XCTAssertFalse(outcome.isVerified)
    }

    func testRemoteParseSSHFailures() {
        let auth = SSHRemoteProbe.parse(exitCode: 255, stdout: "", stderr: "Permission denied (publickey).")
        guard case .authRequired = auth else { return XCTFail("实际 \(auth)") }

        let refused = SSHRemoteProbe.parse(exitCode: 255, stdout: "", stderr: "Connection refused")
        guard case .connectionFailure = refused else { return XCTFail("实际 \(refused)") }
    }

    func testRemoteParseNonProxyStatus() {
        XCTAssertEqual(
            SSHRemoteProbe.parse(exitCode: 0, stdout: "502", stderr: ""),
            .notProxy(statusCode: 502)
        )
    }

    func testRemoteParseGarbageIsUnknown() {
        if case .unknown = SSHRemoteProbe.parse(exitCode: 0, stdout: "", stderr: "") {} else {
            XCTFail("空输出应为 unknown")
        }
        if case .unknown = SSHRemoteProbe.parse(exitCode: 0, stdout: "garbage", stderr: "") {} else {
            XCTFail("垃圾输出应为 unknown")
        }
    }
}
