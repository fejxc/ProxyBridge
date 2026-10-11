import XCTest
@testable import ProxyBridge

/// Mock 隧道服务行为：状态机时序、双连击去重（U14）、用户断开后不再有事件（U13）。
@MainActor
final class MockTunnelServiceTests: XCTestCase {

    private var service = MockTunnelService()
    private var recorder = Recorder<TunnelSnapshot>()

    /// 每个测试装配全新服务（XCTest 的 setUp 重写与 @MainActor 隔离不兼容，故在测试内显式调用）。
    private func makeService(outcome: MockTunnelService.Outcome = .connected) {
        let s = MockTunnelService()
        s.stepDelay = 0.03
        s.outcome = outcome
        let box = recorder
        s.onEvent = { event in
            if case .snapshot(let snap) = event { box.append(snap) }
        }
        service = s
    }

    private func config(endpoint: LocalProxyEndpoint?) -> TunnelConfiguration {
        var profile = ServerProfile(
            name: "测试服务器", host: "10.11.154.192", sshPort: 20064,
            username: "sunyun", remotePort: 7890
        )
        profile.id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        return TunnelConfiguration(profile: profile, localEndpoint: endpoint)
    }

    private var httpEndpoint: LocalProxyEndpoint {
        LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP)
    }

    // MARK: 正常时序

    func testConnectSequenceReachesConnected() async {
        makeService()
        service.connect(configuration: config(endpoint: httpEndpoint))
        let rec = recorder
        let ok = await waitUntil { rec.snapshot.last?.phase == .connected }
        XCTAssertTrue(ok, "应在超时前到达 connected；实际序列：\(recorder.snapshot.map(\.phase))")
        let phases = recorder.snapshot.map(\.phase)
        let firstChecking = phases.firstIndex(of: .checking)
        let firstConnecting = phases.firstIndex(of: .connecting)
        let firstConnected = phases.firstIndex(of: .connected)
        XCTAssertNotNil(firstChecking)
        XCTAssertNotNil(firstConnecting)
        XCTAssertNotNil(firstConnected)
        if let c = firstChecking, let g = firstConnecting, let d = firstConnected {
            XCTAssertTrue(c < g && g < d, "时序必须 checking → connecting → connected")
        }
        let last = recorder.snapshot.last
        XCTAssertEqual(last?.localProxyVerified, true)
        XCTAssertEqual(last?.remoteProbeVerified, true)
        XCTAssertEqual(last?.sshProcessRunning, true)
        XCTAssertNotNil(last?.lastRemoteProbeAt)
    }

    // MARK: U14：同一 profile 双击连接只跑一个序列

    func testDoubleConnectIsIgnored() async {
        makeService()
        let cfg = config(endpoint: httpEndpoint)
        service.connect(configuration: cfg)
        service.connect(configuration: cfg)
        let rec = recorder
        let ok = await waitUntil { rec.snapshot.last?.phase == .connected }
        XCTAssertTrue(ok)
        let checkingCount = recorder.snapshot.filter { $0.phase == .checking }.count
        XCTAssertEqual(checkingCount, 1, "重复连接请求不得产生第二条检查序列")
        let connectedCount = recorder.snapshot.filter { $0.phase == .connected }.count
        XCTAssertEqual(connectedCount, 1, "重复连接请求不得产生第二个 connected 终态")
    }

    // MARK: U13：用户断开 → idle，之后零事件

    func testUserDisconnectStopsAndEmitsNothingAfterwards() async {
        makeService()
        let cfg = config(endpoint: httpEndpoint)
        service.connect(configuration: cfg)
        let rec = recorder
        let started = await waitUntil { rec.snapshot.contains { $0.phase == .checking } }
        XCTAssertTrue(started)

        service.disconnect(profileID: cfg.profile.id)

        let stopped = await waitUntil { rec.snapshot.last?.phase == .idle }
        XCTAssertTrue(stopped)
        let last = recorder.snapshot.last
        XCTAssertTrue(last?.humanReadableDetail.contains("不会自动重连") ?? false)

        // 关键断言：再等一个完整周期，事件数不得增长（无 ghost 重连）
        let countAtStop = recorder.count
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(recorder.count, countAtStop, "用户断开后不得再产生任何事件")
        XCTAssertEqual(recorder.snapshot.last?.phase, .idle)
    }

    // MARK: 本地代理缺失 → degraded（不是 connected；nil=未发现）

    func testMissingLocalEndpointDegrades() async {
        makeService()
        service.connect(configuration: config(endpoint: nil))
        let rec = recorder
        let ok = await waitUntil { rec.snapshot.last?.phase == .degraded }
        XCTAssertTrue(ok)
        // 未解析到端点 = 未发现（nil），与「验证失败」（false）严格区分
        XCTAssertNil(recorder.snapshot.last?.localProxyVerified)
        XCTAssertNil(recorder.snapshot.last?.remoteProbeVerified)
        let presentation = TunnelStatusPresentation.overall(for: recorder.snapshot.last!)
        XCTAssertEqual(presentation.title, "未发现代理")
        XCTAssertEqual(presentation.tone, .orange)
    }

    // MARK: 健康检查不伪造绿色

    func testHealthCheckDoesNotFabricateGreenFromError() async {
        makeService(outcome: .authRequired)
        service.connect(configuration: config(endpoint: httpEndpoint))
        let rec = recorder
        _ = await waitUntil { rec.snapshot.last?.phase == .authRequired }
        service.runHealthCheck(profileID: config(endpoint: nil).profile.id)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(recorder.snapshot.last?.phase, .authRequired, "error/authRequired 不得被检查连接翻成绿色")
        XCTAssertNotEqual(recorder.snapshot.last?.remoteProbeVerified, true)
    }

    // MARK: 剧本注入：认证失败 → authRequired

    func testAuthFailureScenario() async {
        makeService(outcome: .authRequired)
        service.connect(configuration: config(endpoint: httpEndpoint))
        let rec = recorder
        let ok = await waitUntil { rec.snapshot.last?.phase == .authRequired }
        XCTAssertTrue(ok)
        XCTAssertEqual(recorder.snapshot.last?.sshProcessRunning, false)
    }

    // MARK: 剧本注入：远端端口冲突 → error

    func testRemoteBindConflictScenario() async {
        makeService(outcome: .remoteBindConflict)
        service.connect(configuration: config(endpoint: httpEndpoint))
        let rec = recorder
        let ok = await waitUntil { rec.snapshot.last?.phase == .error }
        XCTAssertTrue(ok)
        XCTAssertTrue(recorder.snapshot.last?.humanReadableDetail.contains("占用") ?? false)
    }

    // MARK: 断开后可再次连接

    func testReconnectAfterUserStopIsExplicit() async {
        makeService()
        let cfg = config(endpoint: httpEndpoint)
        service.connect(configuration: cfg)
        let rec = recorder
        _ = await waitUntil { rec.snapshot.last?.phase == .connected }
        service.disconnect(profileID: cfg.profile.id)
        _ = await waitUntil { rec.snapshot.last?.phase == .idle }

        let before = rec.count
        service.connect(configuration: cfg)
        let ok = await waitUntil { rec.count > before && rec.snapshot.last?.phase == .connected }
        XCTAssertTrue(ok, "断开后允许用户显式再次连接")
    }
}
