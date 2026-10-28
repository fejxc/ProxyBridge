import XCTest
@testable import ProxyBridge

// MARK: - 测试替身

final class FakeProxyProvider: SystemProxyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var snapshot: SystemProxySnapshot

    init(snapshot: SystemProxySnapshot) {
        self.snapshot = snapshot
    }

    func setSnapshot(_ newSnapshot: SystemProxySnapshot) {
        lock.lock()
        snapshot = newSnapshot
        lock.unlock()
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func readProxies() -> SystemProxySnapshot {
        lock.lock()
        count += 1
        defer { lock.unlock() }
        return snapshot
    }
}

final class FakeProxyProber: ProxyProbeExecuting, @unchecked Sendable {
    struct Call: Hashable, Sendable {
        let host: String
        let port: Int
        let `protocol`: ProxyProtocol
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    let outcome: ProbeOutcome

    init(outcome: ProbeOutcome) {
        self.outcome = outcome
    }

    var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    var recordedCalls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func probe(host: String, port: Int, protocol: ProxyProtocol, credentials: ProxyCredentials?) async -> ProbeOutcome {
        lock.lock()
        calls.append(Call(host: host, port: port, `protocol`: `protocol`))
        lock.unlock()
        return outcome
    }
}

/// 可控挂起的 prober：验证代次失效（陈旧扫描结果被丢弃）。
final class GatedProxyProber: ProxyProbeExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var continuations: [CheckedContinuation<ProbeOutcome, Never>] = []

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func probe(host: String, port: Int, protocol: ProxyProtocol, credentials: ProxyCredentials?) async -> ProbeOutcome {
        lock.lock()
        calls += 1
        lock.unlock()
        return await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    /// 放行全部挂起的探测。
    func resumeAll(with outcome: ProbeOutcome) {
        lock.lock()
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume(returning: outcome)
        }
    }
}

@MainActor
final class FakeChangeMonitor: SystemProxyChangeMonitoring {
    var onChange: (@MainActor () -> Void)?
    var startSucceeds = true

    func start() -> Bool { startSucceeds }
    func stop() {}

    /// 模拟系统发出一次代理配置变化。
    func fire() {
        onChange?()
    }
}

final class FakeDirectEgressProbe: DirectEgressIPProbing {
    private let result: String?

    init(result: String?) {
        self.result = result
    }

    func probeCurrentNetwork() async -> String? { result }
}

// MARK: - 检测器行为（U15 等）

@MainActor
final class LocalProxyDetectorTests: XCTestCase {

    private let loopbackProxy = SystemProxySnapshot.ExplicitProxy(host: "127.0.0.1", port: 7897)

    private func makeDetector(
        snapshot: SystemProxySnapshot,
        proberOutcome: ProbeOutcome = .verified(statusCode: 200)
    ) -> (LocalProxyDetector, FakeProxyProvider, FakeProxyProber, FakeChangeMonitor, Recorder<ProxyDetectionState>) {
        let provider = FakeProxyProvider(snapshot: snapshot)
        let prober = FakeProxyProber(outcome: proberOutcome)
        let monitor = FakeChangeMonitor()
        let detector = LocalProxyDetector(provider: provider, prober: prober, monitor: monitor)
        let states = Recorder<ProxyDetectionState>()
        detector.onStateChange = { states.append($0) }
        return (detector, provider, prober, monitor, states)
    }

    private var httpSnapshot: SystemProxySnapshot {
        var snap = SystemProxySnapshot()
        snap.http = loopbackProxy
        return snap
    }

    /// U15：连续 5 次变化 → 防抖后只扫描一次。
    func testU15RapidChangesDebounceToSingleScan() async {
        let (detector, provider, _, monitor, _) = makeDetector(snapshot: httpSnapshot)
        detector.debounceSeconds = 0.2
        detector.startObservingSystemChanges()

        for _ in 0..<5 {
            monitor.fire()
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms，全部落在同一防抖窗口
        }

        let scanned = await waitUntilMain { provider.readCount == 1 }
        XCTAssertTrue(scanned, "防抖窗口结束后应恰好扫描一次")
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(provider.readCount, 1, "5 次连续变化只触发一次扫描（U15）")
    }

    func testDebouncedChangeAfterInitialScanRescans() async {
        let (detector, provider, _, monitor, _) = makeDetector(snapshot: httpSnapshot)
        detector.debounceSeconds = 0.1
        detector.startObservingSystemChanges()
        detector.detect()
        let first = await waitUntilMain { provider.readCount == 1 }
        XCTAssertTrue(first)

        monitor.fire()
        let second = await waitUntilMain { provider.readCount == 2 }
        XCTAssertTrue(second, "变化触发一次补充扫描")
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(provider.readCount, 2)
    }

    func testVerifiedOutcomeMarksCandidateAndTimestamp() async {
        let (detector, _, prober, _, states) = makeDetector(snapshot: httpSnapshot)
        detector.detect()
        let done = await waitUntilMain {
            states.snapshot.last?.isScanning == false && states.snapshot.last?.candidates.isEmpty == false
        }
        XCTAssertTrue(done)
        let candidate = states.snapshot.last?.candidates.first
        XCTAssertEqual(candidate?.capability, .verified)
        XCTAssertNotNil(candidate?.endpoint.verifiedAt, "verified 必须带验证时间")
        XCTAssertTrue(candidate?.note?.contains("curl 实测通过") == true)
        XCTAssertEqual(prober.probeCount, 1)
    }

    /// U12 语义在检测器层面的落地：端口开但非代理 → failed 系能力，绝不 verified。
    func testReachableNotProxyOutcomeIsNotVerified() async {
        let (detector, _, _, _, states) = makeDetector(
            snapshot: httpSnapshot,
            proberOutcome: .reachableNotProxy(statusCode: nil)
        )
        detector.detect()
        let done = await waitUntilMain {
            states.snapshot.last?.isScanning == false
        }
        XCTAssertTrue(done)
        let candidate = states.snapshot.last?.candidates.first
        XCTAssertEqual(candidate?.capability, .reachable)
        XCTAssertNil(candidate?.endpoint.verifiedAt, "非代理响应不得写验证时间")
        XCTAssertTrue(candidate?.note?.contains("CONNECT") == true || candidate?.note?.contains("无法作为") == true)
    }

    func testConnectionRefusedOutcome() async {
        let (detector, _, _, _, states) = makeDetector(
            snapshot: httpSnapshot,
            proberOutcome: .connectionRefused
        )
        detector.detect()
        _ = await waitUntilMain { states.snapshot.last?.isScanning == false }
        let candidate = states.snapshot.last?.candidates.first
        XCTAssertEqual(candidate?.capability, .failed)
        XCTAssertTrue(candidate?.note?.contains("未监听") == true)
    }

    func testNonLoopbackCandidatesAreNotProbed() async {
        var snap = SystemProxySnapshot()
        snap.http = SystemProxySnapshot.ExplicitProxy(host: "10.0.0.2", port: 3128)
        let (detector, _, prober, _, states) = makeDetector(snapshot: snap)
        detector.detect()
        _ = await waitUntilMain { states.snapshot.last?.isScanning == false }
        XCTAssertEqual(prober.probeCount, 0, "非回环候选 MVP 不发起探测")
        XCTAssertEqual(states.snapshot.last?.candidates.first?.capability, .untested)
    }

    func testTwoProtocolsProbedSeparately() async {
        var snap = SystemProxySnapshot()
        snap.http = loopbackProxy
        snap.socks = loopbackProxy
        let (detector, _, prober, _, states) = makeDetector(snapshot: snap)
        detector.detect()
        let done = await waitUntilMain {
            states.snapshot.last?.isScanning == false && states.snapshot.last?.candidates.count == 2
        }
        XCTAssertTrue(done)
        XCTAssertEqual(prober.probeCount, 2, "同端口两种协议必须分别实测（U02 落地）")
        // 探测目标必须精确等于候选端点（防接线错位）
        XCTAssertEqual(
            Set(prober.recordedCalls),
            [
                FakeProxyProber.Call(host: "127.0.0.1", port: 7897, protocol: .http),
                FakeProxyProber.Call(host: "127.0.0.1", port: 7897, protocol: .socks5),
            ]
        )
        let capabilities = states.snapshot.last?.candidates.map(\.capability) ?? []
        XCTAssertEqual(capabilities.filter { $0 == .verified }.count, 2)
    }

    /// 回环+非回环混合：只探测回环那一个，且目标正确。
    func testMixedSnapshotProbesOnlyLoopbackTarget() async {
        var snap = SystemProxySnapshot()
        snap.http = SystemProxySnapshot.ExplicitProxy(host: "127.0.0.1", port: 7897)
        snap.socks = SystemProxySnapshot.ExplicitProxy(host: "10.0.0.2", port: 3128)
        let (detector, _, prober, _, states) = makeDetector(snapshot: snap)
        detector.detect()
        let done = await waitUntilMain {
            states.snapshot.last?.isScanning == false && states.snapshot.last?.candidates.count == 2
        }
        XCTAssertTrue(done)
        XCTAssertEqual(prober.probeCount, 1, "非回环候选不探测")
        XCTAssertEqual(prober.recordedCalls.first?.port, 7897)
        XCTAssertEqual(prober.recordedCalls.first?.host, "127.0.0.1")
    }

    /// 代次失效：被新扫描取代的旧扫描结果不得覆盖新状态。
    func testStaleScanResultsAreDiscardedByGeneration() async {
        var snapA = SystemProxySnapshot()
        snapA.http = SystemProxySnapshot.ExplicitProxy(host: "127.0.0.1", port: 7897)
        let provider = FakeProxyProvider(snapshot: snapA)
        let prober = GatedProxyProber()
        let monitor = FakeChangeMonitor()
        let detector = LocalProxyDetector(provider: provider, prober: prober, monitor: monitor)
        let states = Recorder<ProxyDetectionState>()
        detector.onStateChange = { states.append($0) }

        detector.detect() // 扫描 #1：探测被挂起
        let gatedOnce = await waitUntilMain { prober.callCount == 1 }
        XCTAssertTrue(gatedOnce)

        var snapB = SystemProxySnapshot()
        snapB.http = SystemProxySnapshot.ExplicitProxy(host: "127.0.0.1", port: 9999)
        provider.setSnapshot(snapB)
        detector.detect() // 扫描 #2（新代次）
        let gatedTwice = await waitUntilMain { prober.callCount == 2 }
        XCTAssertTrue(gatedTwice)

        prober.resumeAll(with: .verified(statusCode: 200))
        let done = await waitUntilMain {
            states.snapshot.last?.isScanning == false
        }
        XCTAssertTrue(done)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let finalPorts = states.snapshot.last?.candidates.compactMap { $0.endpoint.port } ?? []
        XCTAssertEqual(finalPorts, [9999], "旧扫描（7897）的结果必须被代次守卫丢弃")
    }

    /// 通知链路失败必须如实进入限制说明。
    func testUnhealthyMonitorSurfacesLimitation() async {
        let (detector, _, _, monitor, states) = makeDetector(snapshot: httpSnapshot)
        monitor.startSucceeds = false
        detector.startObservingSystemChanges()
        detector.detect()
        let done = await waitUntilMain { states.snapshot.last?.isScanning == false }
        XCTAssertTrue(done)
        XCTAssertTrue(
            states.snapshot.last?.limitations.contains { $0.contains("通知不可用") } == true,
            "通知链路失效不得静默"
        )
    }

    func testDetectorReportsLiveState() {
        let (detector, _, _, _, states) = makeDetector(snapshot: httpSnapshot)
        // 初始 emit 前不声明 live；首次扫描 emit 后 isLive 必须为 true
        detector.detect()
        let first = states.snapshot.first
        XCTAssertEqual(first?.isLive, true, "真实检测器必须把 isLive 置真，UI 据此区分实测/演示")
    }

    func testPACOnlyScanSetsUnresolvedFlag() async {
        var snap = SystemProxySnapshot()
        snap.pacEnabled = true
        snap.pacURL = "http://pac.example.com/p.pac"
        let (detector, _, _, _, states) = makeDetector(snapshot: snap)
        detector.detect()
        let done = await waitUntilMain { states.snapshot.last?.isScanning == false }
        XCTAssertTrue(done)
        XCTAssertTrue(states.snapshot.last?.systemProxyActiveButUnresolved == true)
        XCTAssertTrue(states.snapshot.last?.candidates.isEmpty == true)
    }

    /// 无本地端口模式需要独立的 Mac 出口指纹；与代理出口字段不能混用。
    func testNoProxyScanPopulatesDirectEgressOnly() async {
        let provider = FakeProxyProvider(snapshot: SystemProxySnapshot())
        let detector = LocalProxyDetector(
            provider: provider,
            prober: FakeProxyProber(outcome: .verified(statusCode: 200)),
            monitor: FakeChangeMonitor(),
            directEgressProber: FakeDirectEgressProbe(result: "203.0.113.7")
        )
        let states = Recorder<ProxyDetectionState>()
        detector.onStateChange = { states.append($0) }

        detector.detect()
        let done = await waitUntilMain { states.snapshot.last?.isScanning == false }
        XCTAssertTrue(done)
        XCTAssertNil(states.snapshot.last?.egressIP)
        XCTAssertEqual(states.snapshot.last?.directEgressIP, "203.0.113.7")
    }

    func testDirectEgressFailureRemainsInconclusive() async {
        let provider = FakeProxyProvider(snapshot: SystemProxySnapshot())
        let detector = LocalProxyDetector(
            provider: provider,
            prober: FakeProxyProber(outcome: .verified(statusCode: 200)),
            monitor: FakeChangeMonitor(),
            directEgressProber: FakeDirectEgressProbe(result: nil)
        )
        let states = Recorder<ProxyDetectionState>()
        detector.onStateChange = { states.append($0) }

        detector.detect()
        let done = await waitUntilMain { states.snapshot.last?.isScanning == false }
        XCTAssertTrue(done)
        XCTAssertNil(states.snapshot.last?.directEgressIP, "探测失败是未知，不是故障结论")
    }

    func testCurrentNetworkEgressArgumentsBypassProxyEnvironment() {
        let args = CurlEgressIPProbe.currentNetworkArguments(connectTimeout: 2, maxTime: 6)
        let proxyIndex = args.firstIndex(of: "--noproxy")
        XCTAssertEqual(proxyIndex.flatMap { args[$0 + 1] }, "*", "当前网络探测必须绕过环境代理")
        XCTAssertEqual(args.last, CurlEgressIPProbe.egressURL)
        XCTAssertTrue(args.contains("--connect-timeout"))
        XCTAssertTrue(args.contains("--max-time"))
    }
}
