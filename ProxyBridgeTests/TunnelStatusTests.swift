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
        pinChineseForTesting()
        let s = snap(phase: .connected, local: nil, sshRunning: true, remote: nil)
        XCTAssertFalse(s.isEndToEndVerified, "remoteProbeVerified == nil 绝不能算端到端已验证")
        XCTAssertTrue(snap(phase: .connected, sshRunning: true, remote: true).isEndToEndVerified)
        XCTAssertFalse(snap(phase: .connected, sshRunning: true, remote: false).isEndToEndVerified)
        XCTAssertFalse(snap(phase: .degraded, sshRunning: true, remote: true).isEndToEndVerified, "非 connected 相不算端到端验证")
    }

    // MARK: 主状态文案表

    func testIdlePresentation() {
        pinChineseForTesting()
        let p = TunnelStatusPresentation.overall(for: snap(phase: .idle))
        XCTAssertEqual(p.title, "未连接")
        XCTAssertEqual(p.tone, .gray)
        XCTAssertEqual(p.detail, "点击连接以建立转发")
    }

    func testCheckingAndConnectingAreBlue() {
        pinChineseForTesting()
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
        pinChineseForTesting()
        // SSH 存活 + 远端已验证 → 绿
        let green = TunnelStatusPresentation.overall(for: snap(phase: .connected, local: true, sshRunning: true, remote: true))
        XCTAssertEqual(green.title, "已连接")
        XCTAssertEqual(green.tone, .green)
        XCTAssertEqual(green.detail, "测试", "状态卡保留协调器给出的实际模式与验活细节")

        // SSH 存活但远端未验证 → 橙（部分可用），绝不显示全绿
        let orange = TunnelStatusPresentation.overall(for: snap(phase: .connected, local: true, sshRunning: true, remote: nil))
        XCTAssertEqual(orange.title, "部分可用")
        XCTAssertEqual(orange.tone, .orange)

        // 远端验证失败同样是橙
        let orangeFail = TunnelStatusPresentation.overall(for: snap(phase: .connected, sshRunning: true, remote: false))
        XCTAssertEqual(orangeFail.tone, .orange)
    }

    func testDegradedLocalProxyDown() {
        pinChineseForTesting()
        let p = TunnelStatusPresentation.overall(for: snap(phase: .degraded, local: false, sshRunning: true))
        XCTAssertEqual(p.title, "代理异常")
        XCTAssertEqual(p.tone, .orange)
    }

    func testAuthRequiredAndErrorAreRed() {
        pinChineseForTesting()
        let auth = TunnelStatusPresentation.overall(for: snap(phase: .authRequired))
        XCTAssertEqual(auth.tone, .red)
        XCTAssertEqual(auth.title, "需要处理")
        XCTAssertEqual(auth.detail, "测试", "authRequired 应透传具体原因（快照 detail）")

        let empty = TunnelStatusPresentation.overall(for: TunnelSnapshot(
            profileId: pid, phase: .authRequired, localProxyVerified: nil,
            sshProcessRunning: false, remoteProbeVerified: nil,
            lastRemoteProbeAt: nil, humanReadableDetail: ""
        ))
        XCTAssertEqual(empty.detail, "检查服务器指纹或 SSH 密钥", "空 detail 回退通用提示")

        let err = TunnelStatusPresentation.overall(for: snap(phase: .error))
        XCTAssertEqual(err.title, "连接失败")
        XCTAssertEqual(err.tone, .red)
    }

    func testDisconnectingIsBlue() {
        pinChineseForTesting()
        XCTAssertEqual(TunnelStatusPresentation.overall(for: snap(phase: .disconnecting)).title, "断开中")
    }

    // MARK: 三层健康映射

    func testHealthTriadForVerifiedConnection() {
        pinChineseForTesting()
        let triad = TunnelStatusPresentation.healthTriad(
            for: snap(phase: .connected, local: true, sshRunning: true, remote: true)
        )
        XCTAssertEqual(triad.local, .ok)
        XCTAssertEqual(triad.ssh, .ok)
        XCTAssertEqual(triad.remote, .ok)
    }

    func testHealthTriadForIdle() {
        pinChineseForTesting()
        let triad = TunnelStatusPresentation.healthTriad(for: snap(phase: .idle))
        XCTAssertEqual(triad.local, .unknown, "idle 时本地未验证（nil）→ unknown，不是 failed")
        XCTAssertEqual(triad.ssh, .failed)
        XCTAssertEqual(triad.remote, .unknown)
    }

    func testHealthTriadSSHProcessDiedWhileConnected() {
        pinChineseForTesting()
        let triad = TunnelStatusPresentation.healthTriad(
            for: snap(phase: .connected, local: true, sshRunning: false, remote: true)
        )
        XCTAssertEqual(triad.ssh, .failed, "进程退出时 SSH 层必须显示失败")
    }

    func testHealthTriadLocalProxyFailedIsFailed() {
        pinChineseForTesting()
        let triad = TunnelStatusPresentation.healthTriad(
            for: snap(phase: .degraded, local: false, sshRunning: true, remote: nil)
        )
        XCTAssertEqual(triad.local, .failed)
        XCTAssertEqual(triad.remote, .unknown)
    }

    // MARK: 健康摘要（折叠规则：全过摘要 / 未验证如实 / 失败展开）

    func testHealthSummaryAllPassIsGreenCountWithFreshVerification() {
        pinChineseForTesting()
        let now = Date()
        let summary = TunnelStatusPresentation.healthSummary(
            checks: [
                (title: "Mac 网络出口", display: .ok),
                (title: "SSH 隧道", display: .ok),
                (title: "远端 SOCKS5", display: .ok)
            ],
            lastVerifiedAt: now.addingTimeInterval(-10),
            now: now
        )
        XCTAssertEqual(summary.title, "3 项检查通过")
        XCTAssertEqual(summary.detail, "刚刚验证")
        XCTAssertEqual(summary.tone, .green)
        XCTAssertFalse(summary.shouldExpandDetails)
        XCTAssertTrue(summary.failedTitles.isEmpty)
    }

    func testHealthSummaryKeepsUnverifiedHonestNeverMergedIntoPassed() {
        pinChineseForTesting()
        let summary = TunnelStatusPresentation.healthSummary(
            checks: [
                (title: "Mac 网络出口", display: .ok),
                (title: "SSH 隧道", display: .ok),
                (title: "远端 SOCKS5", display: .unknown)
            ]
        )
        XCTAssertEqual(summary.title, "2/3 项已验证", "unknown 绝不能并入「通过」")
        XCTAssertEqual(summary.detail, "1 项尚未验证（未验证 ≠ 可用）")
        XCTAssertEqual(summary.tone, .orange)
        XCTAssertFalse(summary.shouldExpandDetails)
    }

    func testHealthSummaryFailureExpandsAndNamesFailedRows() {
        pinChineseForTesting()
        let summary = TunnelStatusPresentation.healthSummary(
            checks: [
                (title: "本地代理", display: .ok),
                (title: "SSH 隧道", display: .failed),
                (title: "远端代理", display: .failed),
                (title: "HTTP 兼容入口", display: .unknown)
            ]
        )
        XCTAssertEqual(summary.title, "2 项检查未通过")
        XCTAssertEqual(summary.tone, .red)
        XCTAssertTrue(summary.shouldExpandDetails, "含失败必须置位自动展开")
        XCTAssertEqual(summary.failedTitles, ["SSH 隧道", "远端代理"])
        XCTAssertEqual(summary.detail, "SSH 隧道、远端代理；另 1 项未验证")
    }

    func testHealthSummaryVerificationAgeSteps() {
        pinChineseForTesting()
        let now = Date()
        XCTAssertEqual(
            TunnelStatusPresentation.healthSummary(
                checks: [(title: "SSH 隧道", display: .ok)],
                lastVerifiedAt: now.addingTimeInterval(-5 * 60),
                now: now
            ).detail,
            "5 分钟前验证"
        )
        XCTAssertNil(
            TunnelStatusPresentation.healthSummary(
                checks: [(title: "SSH 隧道", display: .ok)],
                lastVerifiedAt: nil,
                now: now
            ).detail,
            "没有验证时间就不硬造一条"
        )
        let old = TunnelStatusPresentation.healthSummary(
            checks: [(title: "SSH 隧道", display: .ok)],
            lastVerifiedAt: now.addingTimeInterval(-2 * 3600),
            now: now
        )
        XCTAssertNotNil(old.detail)
        XCTAssertNotEqual(old.detail, "刚刚验证", "超过一小时回退绝对时间而非「刚刚」")
    }

    func testHealthSummaryAllUnknownCountsEverythingUnverified() {
        pinChineseForTesting()
        let summary = TunnelStatusPresentation.healthSummary(
            checks: [
                (title: "本地代理", display: .unknown),
                (title: "SSH 隧道", display: .unknown),
                (title: "远端代理", display: .unknown)
            ]
        )
        XCTAssertEqual(summary.title, "0/3 项已验证")
        XCTAssertEqual(summary.tone, .orange)
    }

    func testHealthSummaryEmptyChecksIsGrayPlaceholder() {
        pinChineseForTesting()
        let summary = TunnelStatusPresentation.healthSummary(checks: [])
        XCTAssertEqual(summary.title, "暂无检查结果")
        XCTAssertEqual(summary.tone, .gray)
        XCTAssertFalse(summary.shouldExpandDetails)
    }

    // MARK: Idle 快照初值

    func testIdleSnapshotDefaults() {
        pinChineseForTesting()
        let s = TunnelSnapshot.idle(pid)
        XCTAssertNil(s.localProxyVerified)
        XCTAssertNil(s.remoteProbeVerified)
        XCTAssertFalse(s.sshProcessRunning)
        XCTAssertNil(s.lastRemoteProbeAt)
        XCTAssertEqual(s.phase, .idle)
    }

    // MARK: 自愈决策展示

    private func recovery(
        state: TunnelRecoveryState,
        action: TunnelRecoveryAction = .rebuildTunnel,
        failures: Int = 3,
        remaining: Int = 1,
        next: Date? = nil
    ) -> TunnelRecoveryDecision {
        TunnelRecoveryDecision(
            scope: .remotePath,
            action: action,
            state: state,
            reason: "远端代理请求失败",
            decidedAt: Date(timeIntervalSince1970: 0),
            nextActionAt: next,
            consecutiveFailures: failures,
            remainingRecoveries: remaining
        )
    }

    func testScheduledRecoveryDecisionPresentation() {
        pinChineseForTesting()
        let now = Date()
        var snapshot = snap(phase: .reconnecting, sshRunning: false)
        snapshot.lastRecoveryDecision = recovery(
            state: .scheduled,
            next: now.addingTimeInterval(3)
        )
        let presentation = TunnelStatusPresentation.recoveryDecision(for: snapshot, now: now)
        XCTAssertEqual(presentation?.title, "自愈决策")
        XCTAssertEqual(presentation?.display, .unknown)
        XCTAssertTrue(presentation?.detail.contains("远端业务通路") ?? false)
        XCTAssertTrue(presentation?.detail.contains("3 秒后执行") ?? false)
        XCTAssertTrue(presentation?.detail.contains("剩余重建预算 1 次") ?? false)
    }

    func testRecoveryDecisionStateMapsToHealthDisplay() {
        pinChineseForTesting()
        var recovered = snap(phase: .connected, local: true, sshRunning: true, remote: true)
        recovered.lastRecoveryDecision = recovery(state: .succeeded, failures: 0, remaining: 1)
        XCTAssertEqual(TunnelStatusPresentation.recoveryDecision(for: recovered)?.display, .ok)

        var executed = snap(phase: .connecting, sshRunning: false)
        executed.lastRecoveryDecision = recovery(state: .executed, next: nil)
        XCTAssertEqual(TunnelStatusPresentation.recoveryDecision(for: executed)?.display, .unknown)

        var exhausted = snap(phase: .degraded, sshRunning: true)
        exhausted.lastRecoveryDecision = recovery(
            state: .budgetExhausted,
            action: .probeOnly,
            remaining: 0
        )
        XCTAssertEqual(TunnelStatusPresentation.recoveryDecision(for: exhausted)?.display, .failed)
    }

    func testSnapshotWithoutRecoveryDecisionHasNoRow() {
        XCTAssertNil(TunnelStatusPresentation.recoveryDecision(for: snap(phase: .degraded, sshRunning: true)))
    }

    /// UI 时间线只保留短环形历史，避免长期故障刷爆菜单栏状态。
    func testRecoveryHistoryKeepsBoundedNewestDecisions() {
        let pid = UUID()
        var snapshot = TunnelSnapshot.idle(pid)
        for index in 0..<8 {
            snapshot.appendRecoveryDecision(recovery(
                state: index % 2 == 0 ? .scheduled : .executed,
                failures: index
            ))
        }
        XCTAssertEqual(snapshot.recoveryHistory.count, 6)
        XCTAssertEqual(snapshot.recoveryHistory.first?.consecutiveFailures, 2)
        XCTAssertEqual(snapshot.recoveryHistory.last?.consecutiveFailures, 7)
        XCTAssertEqual(snapshot.lastRecoveryDecision?.consecutiveFailures, 7)
    }
}
