import XCTest
@testable import ProxyBridge

/// 三态语义（nil ≠ true）与状态→展示映射（03-UI-SPEC §2.1）。
final class TunnelStatusTests: XCTestCase {

    private let pid = UUID()

    private func snap(
        phase: TunnelPhase,
        local: Bool? = nil,
        sshRunning: Bool = false,
        remote: Bool? = nil
    ) -> TunnelSnapshot {
        TunnelSnapshot(
            profileId: pid,
            phase: phase,
            localProxyVerified: local,
            sshProcessRunning: sshRunning,
            remoteProbeVerified: remote,
            lastRemoteProbeAt: nil,
            humanReadableDetail: "测试"
        )
    }

    // MARK: nil ≠ true（验收红线）

    func testNilIsNeverTreatedAsVerified() {
        let s = snap(phase: .connected, local: nil, sshRunning: true, remote: nil)
        XCTAssertFalse(s.isEndToEndVerified, "remoteProbeVerified == nil 绝不能算端到端已验证")
        XCTAssertTrue(snap(phase: .connected, sshRunning: true, remote: true).isEndToEndVerified)
        XCTAssertFalse(snap(phase: .connected, sshRunning: true, remote: false).isEndToEndVerified)
        XCTAssertFalse(snap(phase: .degraded, sshRunning: true, remote: true).isEndToEndVerified, "非 connected 相不算端到端验证")
    }

    // MARK: 主状态文案表

    func testIdlePresentation() {
        let p = TunnelStatusPresentation.overall(for: snap(phase: .idle))
        XCTAssertEqual(p.title, "未连接")
        XCTAssertEqual(p.tone, .gray)
        XCTAssertEqual(p.detail, "点击连接以建立转发")
    }

    func testCheckingAndConnectingAreBlue() {
        XCTAssertEqual(TunnelStatusPresentation.overall(for: snap(phase: .checking)).tone, .blue)
        XCTAssertEqual(TunnelStatusPresentation.overall(for: snap(phase: .checking)).title, "检查中")
        let connecting = TunnelStatusPresentation.overall(for: snap(phase: .connecting))
        XCTAssertEqual(connecting.title, "连接中")
        XCTAssertEqual(connecting.tone, .blue)
        let reconnecting = TunnelStatusPresentation.overall(for: snap(phase: .reconnecting))
        XCTAssertEqual(reconnecting.title, "重连中")
        XCTAssertEqual(reconnecting.tone, .blue)
    }

    func testConnectedRequiresRemoteVerificationForGreen() {
        // SSH 存活 + 远端已验证 → 绿
        let green = TunnelStatusPresentation.overall(for: snap(phase: .connected, local: true, sshRunning: true, remote: true))
        XCTAssertEqual(green.title, "已连接")
        XCTAssertEqual(green.tone, .green)
        XCTAssertEqual(green.detail, "远端代理已验证")

        // SSH 存活但远端未验证 → 橙（部分可用），绝不显示全绿
        let orange = TunnelStatusPresentation.overall(for: snap(phase: .connected, local: true, sshRunning: true, remote: nil))
        XCTAssertEqual(orange.title, "部分可用")
        XCTAssertEqual(orange.tone, .orange)

        // 远端验证失败同样是橙
        let orangeFail = TunnelStatusPresentation.overall(for: snap(phase: .connected, sshRunning: true, remote: false))
        XCTAssertEqual(orangeFail.tone, .orange)
    }

    func testDegradedLocalProxyDown() {
        let p = TunnelStatusPresentation.overall(for: snap(phase: .degraded, local: false, sshRunning: true))
        XCTAssertEqual(p.title, "代理异常")
        XCTAssertEqual(p.tone, .orange)
    }

    func testAuthRequiredAndErrorAreRed() {
        XCTAssertEqual(TunnelStatusPresentation.overall(for: snap(phase: .authRequired)).tone, .red)
        let err = TunnelStatusPresentation.overall(for: snap(phase: .error))
        XCTAssertEqual(err.title, "连接失败")
        XCTAssertEqual(err.tone, .red)
    }

    func testDisconnectingIsBlue() {
        XCTAssertEqual(TunnelStatusPresentation.overall(for: snap(phase: .disconnecting)).title, "断开中")
    }

    // MARK: 三层健康映射

    func testHealthTriadForVerifiedConnection() {
        let triad = TunnelStatusPresentation.healthTriad(
            for: snap(phase: .connected, local: true, sshRunning: true, remote: true)
        )
        XCTAssertEqual(triad.local, .ok)
        XCTAssertEqual(triad.ssh, .ok)
        XCTAssertEqual(triad.remote, .ok)
    }

    func testHealthTriadForIdle() {
        let triad = TunnelStatusPresentation.healthTriad(for: snap(phase: .idle))
        XCTAssertEqual(triad.local, .unknown, "idle 时本地未验证（nil）→ unknown，不是 failed")
        XCTAssertEqual(triad.ssh, .failed)
        XCTAssertEqual(triad.remote, .unknown)
    }

    func testHealthTriadSSHProcessDiedWhileConnected() {
        let triad = TunnelStatusPresentation.healthTriad(
            for: snap(phase: .connected, local: true, sshRunning: false, remote: true)
        )
        XCTAssertEqual(triad.ssh, .failed, "进程退出时 SSH 层必须显示失败")
    }

    func testHealthTriadLocalProxyFailedIsFailed() {
        let triad = TunnelStatusPresentation.healthTriad(
            for: snap(phase: .degraded, local: false, sshRunning: true, remote: nil)
        )
        XCTAssertEqual(triad.local, .failed)
        XCTAssertEqual(triad.remote, .unknown)
    }

    // MARK: Idle 快照初值

    func testIdleSnapshotDefaults() {
        let s = TunnelSnapshot.idle(pid)
        XCTAssertNil(s.localProxyVerified)
        XCTAssertNil(s.remoteProbeVerified)
        XCTAssertFalse(s.sshProcessRunning)
        XCTAssertNil(s.lastRemoteProbeAt)
        XCTAssertEqual(s.phase, .idle)
    }
}
