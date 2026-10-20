import XCTest
@testable import ProxyBridge

// MARK: - 测试替身

/// 可脚本化的进程句柄：按剧本退出/挂起，stderr 可注入。
final class FakeSSHHandle: SSHProcessHandle, @unchecked Sendable {
    var onExit: (@Sendable (Int32) -> Void)?

    private let lock = NSLock()
    private var running = false
    private var code: Int32?
    private var stderr = ""
    private var fired = false
    private(set) var started = false
    private(set) var terminated = false
    var startError: Error?

    func setStderr(_ text: String) {
        lock.lock()
        stderr = text
        lock.unlock()
    }

    var startWasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var wasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if let startError {
            throw startError
        }
        started = true
        running = true
    }

    func simulateExit(_ exitCode: Int32, afterNanoseconds: UInt64 = 0) {
        Task { [weak self] in
            if afterNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: afterNanoseconds)
            }
            guard let self else { return }
            self.lock.lock()
            // 与生产一致：退出回调只发一次（test-and-set）
            guard !self.fired else {
                self.lock.unlock()
                return
            }
            self.fired = true
            self.running = false
            self.code = exitCode
            let callback = self.onExit
            self.lock.unlock()
            callback?(exitCode)
        }
    }

    func terminate() {
        lock.lock()
        terminated = true
        let wasRunning = running
        lock.unlock()
        if wasRunning { simulateExit(15) }
    }

    func forceTerminate() {
        terminate()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var exitCode: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return code
    }

    var stderrTail: String {
        lock.lock()
        defer { lock.unlock() }
        return stderr
    }

    var stdoutTail: String { "" }

    var onPTYOutput: (@Sendable (String) -> Void)?

    /// 记录写入 PTY 的内容（密码流私密性测试用）。
    private(set) var ptyWrites: [String] = []
    func writePTY(_ text: String) {
        lock.lock()
        ptyWrites.append(text)
        lock.unlock()
    }
}

/// 可编排的工厂：记录 make 调用，按队列出句柄（空则自动新建）。
final class FakeSSHFactory: SSHProcessFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [FakeSSHHandle] = []
    private(set) var madeHandles: [FakeSSHHandle] = []
    private(set) var lastArguments: [String] = []
    private(set) var lastEnvironment: [String: String] = [:]

    func enqueue(_ handle: FakeSSHHandle) {
        lock.lock()
        pending.append(handle)
        lock.unlock()
    }

    func make(arguments: [String], environment: [String: String]) -> SSHProcessHandle {
        lock.lock()
        lastArguments = arguments
        lastEnvironment = environment
        let handle = pending.isEmpty ? FakeSSHHandle() : pending.removeFirst()
        madeHandles.append(handle)
        lock.unlock()
        return handle
    }
}

/// 可挂起的本地探测替身（验证 checking 阶段断开的取消路径）。
final class GatedLocalProber: ProxyProbeExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<ProbeOutcome, Never>] = []
    var outcome: ProbeOutcome = .verified(statusCode: 200)

    func probe(host: String, port: Int, protocol: ProxyProtocol) async -> ProbeOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func resumeAll() {
        lock.lock()
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for c in pending { c.resume(returning: outcome) }
    }
}

/// 本地探测替身（可编程结论）。
final class StubLocalProber: ProxyProbeExecuting, @unchecked Sendable {
    var outcome: ProbeOutcome
    private let lock = NSLock()
    private var calls = 0
    init(outcome: ProbeOutcome) { self.outcome = outcome }
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
    private func recordCall() {
        lock.lock()
        calls += 1
        lock.unlock()
    }
    func probe(host: String, port: Int, protocol: ProxyProtocol) async -> ProbeOutcome {
        recordCall()
        return outcome
    }
}

/// 远端探测替身。
final class StubRemoteProber: RemoteProbeExecuting, @unchecked Sendable {
    var outcome: RemoteProbeOutcome
    private let lock = NSLock()
    private var calls = 0
    private var remotePort: Int?
    private var proxyProtocol: ProxyProtocol?
    private var history: [(Int, ProxyProtocol)] = []
    private(set) var lastPassword: String?
    init(outcome: RemoteProbeOutcome) { self.outcome = outcome }
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
    var lastRemotePort: Int? {
        lock.lock()
        defer { lock.unlock() }
        return remotePort
    }
    var lastProtocol: ProxyProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return proxyProtocol
    }
    var probeHistory: [(Int, ProxyProtocol)] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }
    private func record(port: Int, protocol: ProxyProtocol, password: String?) {
        lock.lock()
        calls += 1
        remotePort = port
        proxyProtocol = `protocol`
        history.append((port, `protocol`))
        lastPassword = password
        lock.unlock()
    }
    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol, password: String?) async -> RemoteProbeOutcome {
        record(port: remotePort, protocol: `protocol`, password: password)
        return outcome
    }
}

final class StubRemoteHTTPAdapterManager: RemoteHTTPAdapterManaging, @unchecked Sendable {
    var startResult: RemoteHTTPAdapterStartResult
    private(set) var startCalls = 0
    private(set) var cleanupCalls = 0
    private(set) var lastHTTPPort: Int?
    private(set) var lastSOCKSPort: Int?

    init(startResult: RemoteHTTPAdapterStartResult) { self.startResult = startResult }
    func start(profile: ServerProfile, httpPort: Int, socksPort: Int, password: String?) async -> RemoteHTTPAdapterStartResult {
        startCalls += 1
        lastHTTPPort = httpPort
        lastSOCKSPort = socksPort
        return startResult
    }
    func cleanup(profile: ServerProfile, session: RemoteHTTPAdapterSession, password: String?) async -> RemoteHTTPAdapterCleanupResult {
        cleanupCalls += 1
        return .stopped
    }
}

/// Relay 替身：记录 start/retarget 的目标序列与停止（不监听真实端口）。
final class FakeRelay: TCPRelaying, @unchecked Sendable {
    let sessionID = UUID()
    var onStatistics: (@Sendable (TrafficSnapshot) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var targetHistory: [LocalProxyEndpoint] = []
    private var stopped = false

    private func record(_ target: LocalProxyEndpoint) {
        lock.lock()
        targetHistory.append(target)
        lock.unlock()
    }

    func start(port: UInt16, target: LocalProxyEndpoint) async throws -> UInt16 {
        record(target)
        return 41_000
    }

    func retarget(to target: LocalProxyEndpoint) {
        record(target)
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var targets: [LocalProxyEndpoint] {
        lock.lock(); defer { lock.unlock() }
        return targetHistory
    }
    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}

final class FakeRelayFactory: TCPRelayMaking, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeRelay] = []
    func make(profileID: UUID) -> any TCPRelaying {
        let relay = FakeRelay()
        lock.lock(); made.append(relay); lock.unlock()
        return relay
    }
    var relays: [FakeRelay] {
        lock.lock(); defer { lock.unlock() }
        return made
    }
}

// MARK: - 协调器行为

@MainActor
final class SSHTunnelCoordinatorTests: XCTestCase {

    private var factory = FakeSSHFactory()
    private var localProber = StubLocalProber(outcome: .verified(statusCode: 200))
    private var remoteProber = StubRemoteProber(outcome: .verified(statusCode: 200))
    private var relayFactory = FakeRelayFactory()
    private var coordinator: SSHTunnelCoordinator!
    private var recorder = Recorder<TunnelSnapshot>()
    private var passwordPrompts = Recorder<UUID>()
    private var secretStore = InMemoryPasswordStore()

    /// 装配（在测试内调用：setUp 重写与 @MainActor 隔离不兼容）。
    private func makeCoordinator(
        local: ProbeOutcome = .verified(statusCode: 200),
        remote: RemoteProbeOutcome = .verified(statusCode: 200),
        grace: Double = 0.2,
        adapterManager: (any RemoteHTTPAdapterManaging)? = nil,
        relayFactory: FakeRelayFactory? = nil
    ) {
        factory = FakeSSHFactory()
        localProber = StubLocalProber(outcome: local)
        remoteProber = StubRemoteProber(outcome: remote)
        secretStore = InMemoryPasswordStore()
        if let relayFactory {
            self.relayFactory = relayFactory
        }
        coordinator = SSHTunnelCoordinator(
            processFactory: factory,
            localProber: localProber,
            remoteProber: remoteProber,
            secrets: secretStore,
            relayFactory: self.relayFactory,
            httpAdapterManager: adapterManager
        )
        coordinator.graceSeconds = grace
        recorder = Recorder<TunnelSnapshot>()
        passwordPrompts = Recorder<UUID>()
        let box = recorder
        let prompts = passwordPrompts
        coordinator.onEvent = { event in
            switch event {
            case .snapshot(let snap): box.append(snap)
            case .passwordPromptRequested(let id): prompts.append(id)
            case .traffic: break
            }
        }
    }

    private func configuration(endpoint: LocalProxyEndpoint?) -> TunnelConfiguration {
        var profile = ServerProfile(
            name: "实验室 GPU 服务器", host: "10.11.154.192", sshPort: 20064,
            username: "sunyun", remotePort: 7890
        )
        profile.id = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000001")!
        return TunnelConfiguration(profile: profile, localEndpoint: endpoint)
    }

    private var endpoint: LocalProxyEndpoint {
        LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP)
    }

    private func waitLastPhase(_ phase: TunnelPhase) async -> Bool {
        let box = self.recorder
        return await waitUntilMain { box.snapshot.last?.phase == phase }
    }

    /// 否定断言辅助：等待事件计数在窗口内保持稳定（比固定 sleep 更强的「无后续事件」证据）。
    private func awaitQuiet(countAtStart: Int, stableMilliseconds: Int = 300, timeout: TimeInterval = 3) async -> Bool {
        let box = recorder
        let deadline = Date().addingTimeInterval(timeout)
        var lastChange = Date()
        var last = countAtStart
        while Date() < deadline {
            let boxNow = box
            let current = boxNow.count
            if current != last {
                last = current
                lastChange = Date()
            }
            if current > countAtStart && Int(Date().timeIntervalSince(lastChange) * 1000) >= stableMilliseconds {
                return false // 静默前出现了新事件 → 直接失败
            }
            if current == countAtStart && Int(Date().timeIntervalSince(lastChange) * 1000) >= stableMilliseconds {
                return true // 计数未增长且已稳定
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return box.count == countAtStart
    }

    // MARK: 完整成功序列

    func testFullConnectSequenceReachesConnected() async {
        makeCoordinator()
        coordinator.connect(configuration: configuration(endpoint: endpoint))
        let ok = await waitLastPhase(.connected)
        XCTAssertTrue(ok, "序列：\(recorder.snapshot.map(\.phase))")

        // 时序：checking → connecting → connected
        let phases = recorder.snapshot.map(\.phase)
        let c = phases.firstIndex(of: .checking)
        let g = phases.firstIndex(of: .connecting)
        let d = phases.firstIndex(of: .connected)
        XCTAssertNotNil(c); XCTAssertNotNil(g); XCTAssertNotNil(d)
        if let c, let g, let d { XCTAssertTrue(c < g && g < d) }

        let last = recorder.snapshot.last
        XCTAssertEqual(last?.localProxyVerified, true)
        XCTAssertEqual(last?.remoteProbeVerified, true)
        XCTAssertEqual(last?.sshProcessRunning, true)
        XCTAssertEqual(last?.phase, .connected)
        XCTAssertEqual(last?.isEndToEndVerified, true)
    }

    func testReverseDynamicSkipsLocalProxyAndValidatesRemoteSocks() async {
        makeCoordinator()
        var profile = configuration(endpoint: nil).profile
        profile.connectionMode = .reverseDynamic
        profile.httpAdapterEnabled = false // this test covers SOCKS-only mode
        coordinator.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: nil))

        let connected = await waitLastPhase(.connected)
        XCTAssertTrue(connected, "动态 SOCKS5 不得因本地代理端口缺失而阻断")
        guard let forwardIndex = factory.lastArguments.firstIndex(of: "-R"),
              factory.lastArguments.indices.contains(forwardIndex + 1) else {
            return XCTFail("SSH command must contain the dynamic reverse-forward argument")
        }
        XCTAssertEqual(factory.lastArguments[forwardIndex + 1], "127.0.0.1:17890")
        XCTAssertEqual(localProber.callCount, 0, "动态模式不应调用本地 HTTP/SOCKS 探测")
        XCTAssertEqual(remoteProber.lastRemotePort, 17_890)
        XCTAssertEqual(remoteProber.lastProtocol, .socks5)
        XCTAssertNil(recorder.snapshot.last?.localProxyVerified)
        XCTAssertEqual(recorder.snapshot.last?.effectiveMode, .reverseDynamic)
        XCTAssertEqual(recorder.snapshot.last?.networkReachability, true)
    }

    func testMixedStaticEndpointVerifiesHTTPAndSOCKSSeparately() async {
        makeCoordinator()
        let mixed = LocalProxyEndpoint(host: "127.0.0.1", port: 8890, protocol: .mixed, origin: .manual)
        var profile = configuration(endpoint: mixed).profile
        profile.connectionMode = .staticForward
        coordinator.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: mixed))

        let connected = await waitLastPhase(.connected)
        XCTAssertTrue(connected)
        XCTAssertEqual(localProber.callCount, 2, "Mixed 需验证 HTTP CONNECT 与 SOCKS5 两种入口")
        XCTAssertEqual(remoteProber.lastRemotePort, profile.remotePort)
        XCTAssertEqual(remoteProber.lastProtocol, .mixed)
    }

    /// 动态 SOCKS5 首次远端验证的「监听就绪」竞态：连接拒绝类失败应短退避重试，
    /// 而不是把建立期窗口误报为 degraded（真实日志：首验恒 exit 7，稍后即通过）。
    func testDynamicModeRetriesRefusedRemoteVerifyBeforeDegrading() async {
        final class SequencedRemoteProber: RemoteProbeExecuting, @unchecked Sendable {
            private let lock = NSLock()
            private var outcomes: [RemoteProbeOutcome]
            private(set) var calls = 0
            init(outcomes: [RemoteProbeOutcome]) { self.outcomes = outcomes }
            func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol, password: String?) async -> RemoteProbeOutcome {
                lock.lock(); defer { lock.unlock() }
                calls += 1
                return outcomes.isEmpty ? .unknown(reason: "exhausted") : outcomes.removeFirst()
            }
        }
        let sequenced = SequencedRemoteProber(outcomes: [
            .connectionFailure(reason: "curl exit 7"),
            .connectionFailure(reason: "curl exit 7"),
            .verified(statusCode: 401),
        ])
        makeCoordinator(remote: .verified(statusCode: 200))
        coordinator = SSHTunnelCoordinator(
            processFactory: factory,
            localProber: localProber,
            remoteProber: sequenced,
            secrets: secretStore
        )
        coordinator.graceSeconds = 0.2
        recorder = Recorder<TunnelSnapshot>()
        let box = recorder
        coordinator.onEvent = { if case .snapshot(let s) = $0 { box.append(s) } }

        var profile = configuration(endpoint: nil).profile
        profile.connectionMode = .reverseDynamic
        profile.httpAdapterEnabled = false
        coordinator.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: nil))
        let connected = await waitLastPhase(.connected)
        XCTAssertTrue(connected, "前两次拒绝应被就绪重试消化，第三次验证通过 → connected：\(recorder.snapshot.map(\.phase))")
        XCTAssertEqual(sequenced.calls, 3, "恰好重试两次，不做无限探测")
    }

    // MARK: 本地端点动态跟随（U15：代理变化无缝切换，SSH 不重启）

    func testLocalEndpointRetargetSwitchesRelayWithoutRestartingSSH() async {
        makeCoordinator(relayFactory: FakeRelayFactory())
        var cfg = configuration(endpoint: endpoint)
        cfg.profile.connectionMode = .staticForward
        coordinator.connect(configuration: cfg)
        let ok = await waitLastPhase(.connected)
        XCTAssertTrue(ok, "序列：\(recorder.snapshot.map(\.phase))")
        let handlesBefore = factory.madeHandles.count
        guard let ssh = factory.madeHandles.last else { return XCTFail("应已启动 SSH 进程") }

        let newEndpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 8891, protocol: .socks5, origin: .systemSOCKS)
        coordinator.retargetLocalEndpoint(profileID: cfg.profile.id, endpoint: newEndpoint)
        let switched = await waitUntilMain {
            self.relayFactory.relays.first?.targets.map(\.id) == [self.endpoint.id, newEndpoint.id]
        }
        XCTAssertTrue(switched, "Relay 目标序列应为 [初始端点, 新端点]，实际：\(relayFactory.relays.first?.targets.map(\.displayEndpoint) ?? [])")

        let last = recorder.snapshot.last
        XCTAssertEqual(last?.phase, .connected)
        XCTAssertEqual(last?.activeLocalEndpoint?.id, newEndpoint.id, "会话端点应更新为新端点")
        XCTAssertEqual(last?.remoteProbeVerified, true, "切换后须重验远端")
        XCTAssertEqual(remoteProber.lastProtocol, .socks5, "远端重验须使用新端点协议")
        XCTAssertTrue(last?.humanReadableDetail.contains("无缝切换") == true, "须向用户说明发生了切换：\(last?.humanReadableDetail ?? "")")
        XCTAssertTrue(ssh.isRunning, "SSH 进程不得被重启")
        XCTAssertEqual(factory.madeHandles.count, handlesBefore, "切换不得产生新的 SSH 进程")
    }

    func testLocalEndpointRetargetKeepsEndpointWhenNewFailsVerification() async {
        makeCoordinator(relayFactory: FakeRelayFactory())
        var cfg = configuration(endpoint: endpoint)
        cfg.profile.connectionMode = .staticForward
        coordinator.connect(configuration: cfg)
        _ = await waitLastPhase(.connected)
        localProber.outcome = .connectionRefused // 新端点实测失败（旧端点结论不重探）

        let newEndpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 8892, protocol: .http, origin: .systemHTTP)
        coordinator.retargetLocalEndpoint(profileID: cfg.profile.id, endpoint: newEndpoint)
        let settled = await waitUntilMain {
            self.recorder.snapshot.last?.humanReadableDetail.contains("保持原端点") == true
        }
        XCTAssertTrue(settled, "实测失败须如实说明并保持原端点：\(recorder.snapshot.last?.humanReadableDetail ?? "")")
        XCTAssertEqual(relayFactory.relays.first?.targets.count, 1, "不得切换目标")
        XCTAssertEqual(recorder.snapshot.last?.activeLocalEndpoint?.id, endpoint.id)
        XCTAssertEqual(recorder.snapshot.last?.phase, .connected, "旧端点仍有效时不得翻转状态")
    }

    func testLocalEndpointRetargetIgnoredForIneligibleSessions() async {
        // 动态 SOCKS5 会话不依赖本地端点：不切换
        makeCoordinator()
        var dynamic = configuration(endpoint: nil).profile
        dynamic.connectionMode = .reverseDynamic
        dynamic.httpAdapterEnabled = false
        coordinator.connect(configuration: TunnelConfiguration(profile: dynamic, localEndpoint: nil))
        _ = await waitLastPhase(.connected)
        let probesBefore = localProber.callCount
        let countAtStart = recorder.count
        coordinator.retargetLocalEndpoint(profileID: dynamic.id, endpoint: endpoint)
        let quietDynamic = await awaitQuiet(countAtStart: countAtStart, stableMilliseconds: 200)
        XCTAssertTrue(quietDynamic, "动态模式不得触发切换流程")
        XCTAssertEqual(localProber.callCount, probesBefore)

        // 从未连接的 profile：无会话可切换
        let stranger = configuration(endpoint: endpoint)
        let countBefore = recorder.count
        coordinator.retargetLocalEndpoint(profileID: stranger.profile.id, endpoint: endpoint)
        let quietIdle = await awaitQuiet(countAtStart: countBefore, stableMilliseconds: 200)
        XCTAssertTrue(quietIdle, "无活跃会话时不得有任何事件")
    }

    func testHTTPAdapterStartsOnlyAfterSOCKSProbeAndRequiresHTTPConnect() async {
        let adapterHandle = FakeSSHHandle()
        let manager = StubRemoteHTTPAdapterManager(
            startResult: .started(RemoteHTTPAdapterSession(token: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", handle: adapterHandle))
        )
        makeCoordinator(adapterManager: manager)
        var profile = configuration(endpoint: nil).profile
        profile.connectionMode = .reverseDynamic
        coordinator.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: nil))

        let connected = await waitLastPhase(.connected)
        XCTAssertTrue(connected)
        XCTAssertEqual(manager.startCalls, 1)
        XCTAssertEqual(manager.lastHTTPPort, 7_890)
        XCTAssertEqual(manager.lastSOCKSPort, 17_890)
        XCTAssertEqual(remoteProber.probeHistory.map { $0.1 }, [.socks5, .http], "先验 SOCKS5，再实测 HTTP CONNECT")
        XCTAssertEqual(recorder.snapshot.last?.httpAdapterStatus, .verified)
        XCTAssertEqual(recorder.snapshot.last?.httpAdapterVerified, true)

        coordinator.disconnect(profileID: profile.id)
        let cleaned = await waitUntilMain { manager.cleanupCalls == 1 }
        XCTAssertTrue(cleaned, "断开时应清理本 App 管理的 Privoxy")
    }

    func testHTTPAdapterUnavailableKeepsVerifiedSOCKSAndReportsDegraded() async {
        let manager = StubRemoteHTTPAdapterManager(startResult: .notInstalled)
        makeCoordinator(adapterManager: manager)
        var profile = configuration(endpoint: nil).profile
        profile.connectionMode = .reverseDynamic
        coordinator.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: nil))

        let degraded = await waitLastPhase(.degraded)
        XCTAssertTrue(degraded)
        XCTAssertEqual(remoteProber.callCount, 1, "HTTP 探测不能在 Privoxy 不存在时伪装执行")
        XCTAssertEqual(recorder.snapshot.last?.remoteProbeVerified, true, "SOCKS5 仍保留已验证结论")
        XCTAssertEqual(recorder.snapshot.last?.effectiveMode, .reverseDynamic)
        XCTAssertEqual(recorder.snapshot.last?.httpAdapterStatus, .notInstalled)
        XCTAssertTrue(recorder.snapshot.last?.humanReadableDetail.contains("SOCKS5 端到端请求已验证") == true)
    }

    // MARK: I01：进程 0.5s 后异常退出 → 分类进入终态

    func testI01ProcessEarlyExitClassifiedFromStderr() async {
        makeCoordinator(grace: 1.5)
        let handle = FakeSSHHandle()
        factory.enqueue(handle)
        coordinator.connect(configuration: configuration(endpoint: endpoint))

        // 进程启动后很快带着 Permission denied 退出
        let waitStarted = await waitUntil { handle.startWasCalled }
        XCTAssertTrue(waitStarted)
        handle.setStderr("sunyun@10.11.154.192: Permission denied (publickey).")
        handle.simulateExit(255)

        let ok = await waitLastPhase(.authRequired)
        XCTAssertTrue(ok, "认证失败必须进入 authRequired；序列：\(recorder.snapshot.map(\.phase))")
    }

    func testEarlyExitWithForwardFailureIsError() async {
        makeCoordinator(grace: 1.5)
        let handle = FakeSSHHandle()
        factory.enqueue(handle)
        coordinator.connect(configuration: configuration(endpoint: endpoint))
        _ = await waitUntil { handle.startWasCalled }
        handle.setStderr("Warning: remote port forwarding failed for listen port 7890")
        handle.simulateExit(255)

        let ok = await waitLastPhase(.error)
        XCTAssertTrue(ok)
        XCTAssertTrue(recorder.snapshot.last?.humanReadableDetail.contains("端口") == true)
    }

    // MARK: I02：SSH 正常但本地代理后来失败 → degraded 而非 connected

    func testI02LocalProxyFailureDegradesNotConnected() async {
        makeCoordinator(local: .connectionRefused)
        var config = configuration(endpoint: endpoint)
        config.profile.connectionMode = .staticForward
        coordinator.connect(configuration: config)
        let ok = await waitLastPhase(.degraded)
        XCTAssertTrue(ok, "本地代理失败必须 degraded；序列：\(recorder.snapshot.map(\.phase))")
        XCTAssertEqual(recorder.snapshot.last?.localProxyVerified, false)
        XCTAssertNotEqual(recorder.snapshot.last?.phase, .connected)
    }

    // MARK: I03：手动断开时有在途任务 → 取消 + 零 ghost 事件

    func testI03DisconnectDuringSetupStopsEverything() async {
        makeCoordinator(grace: 5.0) // 长宽限，制造在途窗口
        coordinator.connect(configuration: configuration(endpoint: endpoint))
        let box = recorder
        let started = await waitUntilMain { box.snapshot.contains { $0.phase == .connecting } }
        XCTAssertTrue(started)

        coordinator.disconnect(profileID: configuration(endpoint: endpoint).profile.id)

        let stopped = await waitLastPhase(.idle)
        XCTAssertTrue(stopped)
        XCTAssertTrue(factory.madeHandles.last?.wasTerminated == true, "必须终止本 App 拥有的进程")

        let countAtStop = recorder.count
        let quiet = await awaitQuiet(countAtStart: countAtStop, stableMilliseconds: 400)
        XCTAssertTrue(quiet, "断开后不得再有事件（I03/U13）")
        XCTAssertEqual(recorder.snapshot.last?.phase, .idle)
    }

    // MARK: I04：进程启动失败 → 明确状态、无泄漏

    func testI04LaunchFailureReportsErrorAndCleansUp() async {
        makeCoordinator()
        let broken = FakeSSHHandle()
        broken.startError = NSError(domain: "test", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "permission denied launching"])
        factory.enqueue(broken)
        coordinator.connect(configuration: configuration(endpoint: endpoint))

        let ok = await waitLastPhase(.error)
        XCTAssertTrue(ok)
        XCTAssertTrue(recorder.snapshot.last?.humanReadableDetail.contains("无法启动 SSH 进程") == true)
        XCTAssertFalse(coordinator.isActive(profileID: configuration(endpoint: endpoint).profile.id),
                       "失败后不得残留活跃状态")
    }

    // MARK: U14：双连击只跑一个序列

    func testU14DoubleConnectIgnored() async {
        makeCoordinator(grace: 0.4)
        let cfg = configuration(endpoint: endpoint)
        coordinator.connect(configuration: cfg)
        coordinator.connect(configuration: cfg)
        let ok = await waitLastPhase(.connected)
        XCTAssertTrue(ok)
        XCTAssertEqual(factory.madeHandles.count, 1, "重复连接不得创建第二个进程")
        XCTAssertEqual(recorder.snapshot.filter { $0.phase == .checking }.count, 1)
    }

    // MARK: 无端点 / 远端 unknown 语义

    func testMissingEndpointDegradesWithNilSemantics() async {
        makeCoordinator()
        var profile = configuration(endpoint: nil).profile
        profile.connectionMode = .staticForward
        coordinator.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: nil))
        let ok = await waitLastPhase(.degraded)
        XCTAssertTrue(ok)
        let last = recorder.snapshot.last
        XCTAssertNil(last?.localProxyVerified, "未发现端点 = nil（≠ false）")
        XCTAssertNil(last?.remoteProbeVerified)
        XCTAssertFalse(factory.madeHandles.contains { $0.startWasCalled }, "无端点不得启动 SSH")
    }

    func testAutomaticWithoutLocalEndpointFallsBackToDynamicSocks() async {
        makeCoordinator()
        var config = configuration(endpoint: nil)
        config.profile.httpAdapterEnabled = false // this test covers SOCKS-only fallback
        coordinator.connect(configuration: config)

        let connected = await waitLastPhase(.connected)
        XCTAssertTrue(connected, "自动模式无本地端点时应尝试动态 SOCKS5")
        XCTAssertEqual(localProber.callCount, 0)
        XCTAssertEqual(remoteProber.lastRemotePort, 17_890)
        XCTAssertEqual(remoteProber.lastProtocol, .socks5)
        XCTAssertEqual(recorder.snapshot.last?.effectiveMode, .reverseDynamic)
        XCTAssertTrue(recorder.snapshot.last?.selectionReason?.contains("未发现") == true)
    }

    func testAutomaticFallsBackWhenLocalProxyProbeFails() async {
        makeCoordinator(local: .connectionRefused)
        var config = configuration(endpoint: endpoint)
        config.profile.httpAdapterEnabled = false // this test covers SOCKS-only fallback
        coordinator.connect(configuration: config)

        let connected = await waitLastPhase(.connected)
        XCTAssertTrue(connected, "自动模式应从失效的本地入口回退")
        XCTAssertEqual(localProber.callCount, 1)
        XCTAssertEqual(remoteProber.lastRemotePort, 17_890)
        XCTAssertEqual(remoteProber.lastProtocol, .socks5)
        XCTAssertEqual(recorder.snapshot.last?.effectiveMode, .reverseDynamic)
        XCTAssertNil(recorder.snapshot.last?.localProxyVerified, "回退后本地端口不再是运行依赖")
        XCTAssertTrue(recorder.snapshot.last?.selectionReason?.contains("未通过实测") == true)
    }

    /// U11 语义：远端缺 curl → degraded + remoteProbe=unknown，绝不 connected。
    func testRemoteCurlMissingIsDegradedNotConnected() async {
        makeCoordinator(remote: .remoteCurlMissing)
        coordinator.connect(configuration: configuration(endpoint: endpoint))
        let ok = await waitLastPhase(.degraded)
        XCTAssertTrue(ok)
        let last = recorder.snapshot.last
        XCTAssertEqual(last?.localProxyVerified, true)
        XCTAssertNil(last?.remoteProbeVerified, "缺 curl = 未验证（nil）")
        XCTAssertTrue(last?.humanReadableDetail.contains("缺少 curl") == true)
        XCTAssertNotEqual(last?.phase, .connected)
    }

    func testRemoteFailureIsDegradedWithFalse() async {
        makeCoordinator(remote: .notProxy(statusCode: 502))
        coordinator.connect(configuration: configuration(endpoint: endpoint))
        let ok = await waitLastPhase(.degraded)
        XCTAssertTrue(ok)
        XCTAssertEqual(recorder.snapshot.last?.remoteProbeVerified, false)
    }

    // MARK: 进程中途死亡（已 connected 后）

    func testProcessDeathAfterConnectedEntersErrorWithClassification() async {
        makeCoordinator(grace: 0.1)
        coordinator.connect(configuration: configuration(endpoint: endpoint))
        let connected = await waitLastPhase(.connected)
        XCTAssertTrue(connected)

        let handle = factory.madeHandles.last
        handle?.setStderr("Connection timed out")
        handle?.simulateExit(255)

        let errored = await waitLastPhase(.error)
        XCTAssertTrue(errored)
        XCTAssertTrue(recorder.snapshot.last?.humanReadableDetail.contains("超时") == true)
    }

    // MARK: 用户断开后的进程退出被静默（U13 双保险）

    func testExitAfterUserStopIsSilent() async {
        makeCoordinator(grace: 0.1)
        let cfg = configuration(endpoint: endpoint)
        coordinator.connect(configuration: cfg)
        let connected = await waitLastPhase(.connected)
        XCTAssertTrue(connected)

        coordinator.disconnect(profileID: cfg.profile.id)
        let idle = await waitLastPhase(.idle)
        XCTAssertTrue(idle)

        let count = recorder.count
        factory.madeHandles.last?.simulateExit(15) // SIGTERM 退出
        let quiet = await awaitQuiet(countAtStart: count, stableMilliseconds: 300)
        XCTAssertTrue(quiet, "用户断开后的进程退出不得产生事件")
    }

    // MARK: 断开后重连（Session 替换）

    func testReconnectAfterDisconnectGetsFreshSession() async {
        makeCoordinator(grace: 0.1)
        let cfg = configuration(endpoint: endpoint)
        coordinator.connect(configuration: cfg)
        _ = await waitLastPhase(.connected)
        coordinator.disconnect(profileID: cfg.profile.id)
        _ = await waitLastPhase(.idle)

        let countAtIdle = recorder.count
        coordinator.connect(configuration: cfg) // 用户显式重连
        let reconnected = await waitLastPhase(.connected)
        XCTAssertTrue(reconnected, "断开后允许用户显式重连（userStopped 不得残留拦截）")
        XCTAssertEqual(factory.madeHandles.count, 2, "重连必须创建全新会话/进程")
        XCTAssertGreaterThan(recorder.count, countAtIdle)
        let last = recorder.snapshot.last
        XCTAssertEqual(last?.phase, .connected)
        XCTAssertEqual(last?.localProxyVerified, true)
    }

    // MARK: checking 阶段断开（本地探测在途的取消路径）

    func testDisconnectDuringCheckingAbortsSilently() async {
        let gate = GatedLocalProber()
        factory = FakeSSHFactory()
        remoteProber = StubRemoteProber(outcome: .verified(statusCode: 200))
        coordinator = SSHTunnelCoordinator(
            processFactory: factory, localProber: gate, remoteProber: remoteProber,
            secrets: InMemoryPasswordStore()
        )
        coordinator.graceSeconds = 0.1
        recorder = Recorder<TunnelSnapshot>()
        let box = recorder
        coordinator.onEvent = { event in
            if case .snapshot(let snap) = event { box.append(snap) }
        }

        let cfg = configuration(endpoint: endpoint)
        coordinator.connect(configuration: cfg)
        let checking = await waitUntilMain { box.snapshot.last?.phase == .checking }
        XCTAssertTrue(checking)

        coordinator.disconnect(profileID: cfg.profile.id) // 本地探测仍挂起
        let idle = await waitLastPhase(.idle)
        XCTAssertTrue(idle)

        gate.resumeAll() // 迟到的探测结果
        let quiet = await awaitQuiet(countAtStart: recorder.count, stableMilliseconds: 400)
        XCTAssertTrue(quiet, "checking 阶段断开后，迟到的探测结果不得产生事件")
        XCTAssertFalse(factory.madeHandles.contains { $0.startWasCalled }, "取消路径不得启动 SSH 进程")
    }

    // MARK: 前置检查

    func testPreflightFailsOnMissingKeyFile() async {
        makeCoordinator()
        var profile = ServerProfile(
            name: "k", host: "10.11.154.192", sshPort: 22,
            username: "sunyun", authMode: .identityFile,
            identityFilePath: "/nonexistent/proxybridge-test-key", remotePort: 7890
        )
        profile.id = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000002")!
        coordinator.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: endpoint))

        let ok = await waitLastPhase(.error)
        XCTAssertTrue(ok)
        XCTAssertTrue(recorder.snapshot.last?.humanReadableDetail.contains("密钥文件不存在") == true)
        XCTAssertFalse(factory.madeHandles.contains { $0.startWasCalled }, "前置检查失败不得启动进程")
    }

    // MARK: 健康检查

    func testHealthCheckOnConnectedRefreshesRemoteAndKeepsPhase() async {
        makeCoordinator()
        coordinator.remoteProbeCooldown = 0 // 走远端复核分支
        let cfg = configuration(endpoint: endpoint)
        coordinator.connect(configuration: cfg)
        _ = await waitLastPhase(.connected)
        let callsBefore = remoteProber.callCount

        coordinator.runHealthCheck(profileID: cfg.profile.id)
        let box = recorder
        let refreshed = await waitUntilMain { box.snapshot.last?.humanReadableDetail.contains("手动检查") == true }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(recorder.snapshot.last?.phase, .connected, "全部通过保持 connected")
        XCTAssertGreaterThan(remoteProber.callCount, callsBefore, "冷却过后必须真的重探远端")
    }

    func testHealthCheckDegradedWhenRemoteFailsLater() async {
        makeCoordinator()
        coordinator.remoteProbeCooldown = 0
        let cfg = configuration(endpoint: endpoint)
        coordinator.connect(configuration: cfg)
        _ = await waitLastPhase(.connected)

        remoteProber.outcome = .notProxy(statusCode: 502) // 远端此后失败
        coordinator.runHealthCheck(profileID: cfg.profile.id)
        let box = recorder
        let refreshed = await waitUntilMain { box.snapshot.last?.humanReadableDetail.contains("手动检查") == true }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(recorder.snapshot.last?.phase, .degraded, "远端复核失败必须降级，不保留旧绿")
        XCTAssertEqual(recorder.snapshot.last?.remoteProbeVerified, false)
    }

    func testHealthCheckNeverFlipsErrorTerminal() async {
        makeCoordinator(grace: 0.1)
        let cfg = configuration(endpoint: endpoint)
        coordinator.connect(configuration: cfg)
        _ = await waitLastPhase(.connected)

        // 进程死亡 → error 终态
        let handle = factory.madeHandles.last
        handle?.setStderr("Connection timed out")
        handle?.simulateExit(255)
        _ = await waitLastPhase(.error)

        let count = recorder.count
        coordinator.remoteProbeCooldown = 0
        coordinator.runHealthCheck(profileID: cfg.profile.id) // error 终态必须 no-op
        let quiet = await awaitQuiet(countAtStart: count, stableMilliseconds: 300)
        XCTAssertTrue(quiet, "error 终态下健康检查不得产生事件")
        XCTAssertEqual(recorder.snapshot.last?.phase, .error, "error 终态不得被翻转")
    }

    /// 高危回归：健康检查与进程死亡竞争时，error 终态不得被探测结果翻回绿色。
    func testHealthCheckRacingProcessDeathStaysError() async {
        makeCoordinator()
        coordinator.remoteProbeCooldown = 0
        let cfg = configuration(endpoint: endpoint)
        coordinator.connect(configuration: cfg)
        _ = await waitLastPhase(.connected)

        // 健康检查进行中（远端探测在途）进程死亡
        coordinator.runHealthCheck(profileID: cfg.profile.id)
        let handle = factory.madeHandles.last
        handle?.setStderr("Connection timed out")
        handle?.simulateExit(255)
        _ = await waitLastPhase(.error)

        try? await Task.sleep(nanoseconds: 400_000_000)
        let phases = recorder.snapshot.map(\.phase)
        XCTAssertFalse(phases.dropFirst(phases.firstIndex(of: .error) ?? 0).contains(.connected),
                       "error 之后不得出现 connected（假绿）")
        XCTAssertEqual(recorder.snapshot.last?.phase, .error)
        let last = recorder.snapshot.last
        XCTAssertFalse(last?.isEndToEndVerified == true, "ssh 已死时不得呈端到端已验证")
    }

    // MARK: 密码模式（PTY 握手）

    private func passwordProfile() -> ServerProfile {
        var p = ServerProfile(
            name: "密码机", host: "10.11.154.192", sshPort: 22,
            username: "root", authMode: .password, remotePort: 7890
        )
        p.id = UUID(uuidString: "ABCDEF00-0000-0000-0000-0000000000C0")!
        return p
    }

    func testPasswordFlowPromptsSubmitsAndConnects() async {
        makeCoordinator(grace: 0.1)
        let handle = FakeSSHHandle()
        factory.enqueue(handle)
        let cfg = TunnelConfiguration(profile: passwordProfile(), localEndpoint: endpoint)

        coordinator.connect(configuration: cfg)
        // ssh 启动后出现密码提示
        _ = await waitUntil { handle.startWasCalled }
        handle.setStderr("root@10.11.154.192's password:")
        let prompts = passwordPrompts
        let prompted = await waitUntilMain { prompts.snapshot.last == cfg.profile.id }
        XCTAssertTrue(prompted, "检测到提示后必须请求 UI 输入密码")

        coordinator.submitPassword(profileID: cfg.profile.id, password: "s3cret-value", remember: false)
        let connected = await waitLastPhase(.connected)
        XCTAssertTrue(connected)

        // 密码经 PTY 交给 ssh（含换行）
        XCTAssertEqual(handle.ptyWrites.last, "s3cret-value\n")
        // 远端探测复用会话密码
        let prober = remoteProber
        let remotePass = await waitUntilMain { prober.lastPassword != nil }
        XCTAssertTrue(remotePass)
        XCTAssertEqual(prober.lastPassword, "s3cret-value")

        // 私密性：所有快照/日志 detail 绝不包含密码
        let leaked = recorder.snapshot.contains { $0.humanReadableDetail.contains("s3cret-value") }
        XCTAssertFalse(leaked, "密码不得出现在任何状态文案中")
    }

    func testCancelPasswordPromptEndsInIdleWithNoGhostEvents() async {
        makeCoordinator(grace: 0.1)
        let handle = FakeSSHHandle()
        factory.enqueue(handle)
        let cfg = TunnelConfiguration(profile: passwordProfile(), localEndpoint: endpoint)
        coordinator.connect(configuration: cfg)
        _ = await waitUntil { handle.startWasCalled }
        handle.setStderr("root@10.11.154.192's password:")
        let prompts = passwordPrompts
        let prompted = await waitUntilMain { prompts.snapshot.last == cfg.profile.id }
        XCTAssertTrue(prompted)

        coordinator.cancelPasswordPrompt(profileID: cfg.profile.id)
        let idle = await waitLastPhase(.idle)
        XCTAssertTrue(idle)
        let quiet = await awaitQuiet(countAtStart: recorder.count, stableMilliseconds: 300)
        XCTAssertTrue(quiet, "取消后不得再有事件")
        XCTAssertTrue(handle.wasTerminated, "取消必须终止本次 ssh 尝试")
    }

    // MARK: 记住密码（钥匙串）

    /// 会话内密码记忆：网络级死亡后的重连不再询问；用户断开后作废重新询问。
    func testSessionPasswordReusedOnReconnectButNotAfterUserDisconnect() async {
        makeCoordinator(grace: 0.1)
        let handle1 = FakeSSHHandle()
        factory.enqueue(handle1)
        let cfg = TunnelConfiguration(profile: passwordProfile(), localEndpoint: endpoint)

        coordinator.connect(configuration: cfg)
        _ = await waitUntil { handle1.startWasCalled }
        handle1.setStderr("root@10.11.154.192's password:")
        let prompts = passwordPrompts
        _ = await waitUntilMain { prompts.snapshot.last == cfg.profile.id }
        coordinator.submitPassword(profileID: cfg.profile.id, password: "s3cret-value", remember: false)
        _ = await waitLastPhase(.connected)

        // 模拟网络级死亡（非认证失败、非用户断开）→ error
        handle1.setStderr("Connection reset by peer")
        handle1.simulateExit(255)
        _ = await waitLastPhase(.error)

        // 重连：新 ssh 再要密码——会话内记忆直接应答，不再请求 UI
        let handle2 = FakeSSHHandle()
        factory.enqueue(handle2)
        coordinator.connect(configuration: cfg)
        _ = await waitUntil { handle2.startWasCalled }
        handle2.setStderr("root@10.11.154.192's password:")
        let connectedAgain = await waitLastPhase(.connected)
        XCTAssertTrue(connectedAgain)
        XCTAssertEqual(handle2.ptyWrites.last, "s3cret-value\n", "重连应复用会话内密码")
        XCTAssertEqual(prompts.snapshot.filter { $0 == cfg.profile.id }.count, 1, "第二次连接不得再请求 UI 输入")

        // 用户主动断开 → 会话内密码作废，再连必须重新询问
        coordinator.disconnect(profileID: cfg.profile.id)
        _ = await waitLastPhase(.idle)
        let handle3 = FakeSSHHandle()
        factory.enqueue(handle3)
        coordinator.connect(configuration: cfg)
        _ = await waitUntil { handle3.startWasCalled }
        handle3.setStderr("root@10.11.154.192's password:")
        let promptedAgain = await waitUntilMain { prompts.snapshot.filter { $0 == cfg.profile.id }.count == 2 }
        XCTAssertTrue(promptedAgain, "用户断开后必须重新询问密码")
        coordinator.disconnect(profileID: cfg.profile.id)
    }

    func testRememberedPasswordAutoAnswersWithoutPrompt() async {
        makeCoordinator(grace: 0.1)
        let cfg = configuration(endpoint: endpoint)
        var p = cfg.profile
        p.authMode = .password
        p.rememberPassword = true
        let remembered = TunnelConfiguration(profile: p, localEndpoint: endpoint)
        secretStore.save("stored-pass", for: p.id)

        let handle = FakeSSHHandle()
        factory.enqueue(handle)
        coordinator.connect(configuration: remembered)
        _ = await waitUntil { handle.startWasCalled }
        handle.setStderr("root@10.11.154.192's password:")
        let connected = await waitLastPhase(.connected)
        XCTAssertTrue(connected)

        let prompts = passwordPrompts
        XCTAssertNil(prompts.snapshot.last, "已记住密码必须自动应答，不请求 UI 输入")
        XCTAssertEqual(handle.ptyWrites.last, "stored-pass\n")
        let prober = remoteProber
        XCTAssertEqual(prober.lastPassword, "stored-pass")
    }

    func testAuthFailureClearsRememberedPassword() async {
        makeCoordinator(grace: 0.1)
        let cfg = configuration(endpoint: endpoint)
        var p = cfg.profile
        p.authMode = .password
        p.rememberPassword = true
        let remembered = TunnelConfiguration(profile: p, localEndpoint: endpoint)
        secretStore.save("wrong-pass", for: p.id)

        let handle = FakeSSHHandle()
        factory.enqueue(handle)
        coordinator.connect(configuration: remembered)
        _ = await waitUntil { handle.startWasCalled }
        handle.setStderr("root@10.11.154.192's password:")
        // 自动应答后认证失败
        let autoAnswered = await waitUntil { !handle.ptyWrites.isEmpty }
        XCTAssertTrue(autoAnswered)
        handle.setStderr("Permission denied (publickey).")
        handle.simulateExit(255)

        let authRequired = await waitLastPhase(.authRequired)
        XCTAssertTrue(authRequired)
        XCTAssertNil(secretStore.load(for: p.id), "认证失败必须清除记住的密码")
        XCTAssertTrue(recorder.snapshot.last?.humanReadableDetail.contains("已清除记住的密码") == true)
    }

    // MARK: ssh 环境白名单

    func testSSHEnvironmentWhitelist() async {
        makeCoordinator()
        let cfg = configuration(endpoint: endpoint)
        coordinator.connect(configuration: cfg)
        _ = await waitLastPhase(.connected)

        let env = factory.lastEnvironment
        XCTAssertEqual(Set(env.keys).subtracting(["PATH", "HOME", "SSH_AUTH_SOCK"]), [],
                       "ssh 环境只允许 PATH/HOME/SSH_AUTH_SOCK（实际：\(env.keys)）")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(env["HOME"], NSHomeDirectory())
    }

    func testHealthCheckNeverRunsWhenIdle() async {
        makeCoordinator()
        let cfg = configuration(endpoint: endpoint)
        coordinator.runHealthCheck(profileID: cfg.profile.id)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(recorder.snapshot.isEmpty, "idle 时健康检查必须无操作")
        XCTAssertEqual(remoteProber.callCount, 0)
    }
}
