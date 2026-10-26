import XCTest
@testable import ProxyBridge

/// 记录调用的隧道服务替身。
@MainActor
final class TunnelSpy: TunnelService {
    var onEvent: (@MainActor (TunnelEvent) -> Void)?
    private(set) var connectCalls: [TunnelConfiguration] = []
    private(set) var disconnectCalls: [UUID] = []
    private(set) var systemDisconnectCalls: [(profileID: UUID, reason: String)] = []
    private(set) var healthCheckCalls: [UUID] = []
    private(set) var retargetCalls: [(profileID: UUID, endpoint: LocalProxyEndpoint)] = []
    var activeIDs: Set<UUID> = []

    func connect(configuration: TunnelConfiguration) {
        connectCalls.append(configuration)
    }

    func disconnect(profileID: UUID) {
        disconnectCalls.append(profileID)
    }

    func disconnectForSystemReason(profileID: UUID, reason: String) {
        systemDisconnectCalls.append((profileID, reason))
        disconnect(profileID: profileID)
    }

    func runHealthCheck(profileID: UUID) {
        healthCheckCalls.append(profileID)
    }

    func retargetLocalEndpoint(profileID: UUID, endpoint: LocalProxyEndpoint) {
        retargetCalls.append((profileID, endpoint))
    }

    func isActive(profileID: UUID) -> Bool {
        activeIDs.contains(profileID)
    }

    func terminateAllSessions() {
        disconnectCalls.append(contentsOf: activeIDs)
        activeIDs.removeAll()
    }

    func submitPassword(profileID: UUID, password: String, remember: Bool) {}
    private(set) var rememberedPassword: String?
    var secrets: PasswordStoring { InMemoryPasswordStore() }
    func cancelPasswordPrompt(profileID: UUID) {
        disconnectCalls.append(profileID)
    }

    /// 测试注入：模拟服务上报快照。
    func emit(_ snapshot: TunnelSnapshot) {
        onEvent?(.snapshot(snapshot))
    }
}

/// ViewModel 行为：持久化联动、校验拦截、事件应用、手动端点优先。
@MainActor
final class AppViewModelTests: XCTestCase {

    @discardableResult
    private func makeModel(directory: URL) -> (model: AppViewModel, tunnel: TunnelSpy, detector: MockProxyDetector) {
        let spy = TunnelSpy()
        let detector = MockProxyDetector()
        detector.simulatedLatency = 0.02
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: directory),
            settingsStore: AppSettingsStore(directoryURL: directory),
            tunnel: spy,
            proxyDetector: detector,
            logStore: LogStore(),
            secrets: InMemoryPasswordStore()
        )
        return (model, spy, detector)
    }

    /// 每个测试自建临时目录并在结束时清理（XCTest 的 setUp/tearDown 重写与 @MainActor 隔离不兼容）。
    private func withTempDir() -> TempDirectory {
        TempDirectory.make()
    }

    private func validProfile(name: String = "测试机") -> ServerProfile {
        ServerProfile(name: name, host: "10.11.154.192", sshPort: 20064, username: "sunyun", remotePort: 17891)
    }

    // MARK: 启动装配

    func testBootstrapEmptyStartsDetection() async {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, _, _) = makeModel(directory: temp.url)
        pinChineseForTesting() // model 初始化会把语言切到跟随系统（CI=en）
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertTrue(model.overallPresentation.title == "未配置")
        let gotCandidates = await waitUntilMain { !model.detection.candidates.isEmpty }
        XCTAssertTrue(gotCandidates, "Mock 检测器应产出候选（测试替身）")
        XCTAssertFalse(model.detection.limitations.isEmpty, "测试替身必须注明非实测")
    }

    func testBootstrapLoadsPersistedProfiles() {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let p = validProfile()
        let doc = ProfilesDocument(schemaVersion: 1, profiles: [p], currentProfileId: p.id)
        try? ProfileRepository(directoryURL: temp.url).save(doc)

        let (model, _, _) = makeModel(directory: temp.url)
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertEqual(model.currentProfileId, p.id)
        XCTAssertEqual(model.currentSnapshot.phase, .idle)
    }

    // MARK: 健康摘要装配（菜单栏折叠行，概览页将共用）

    func testHealthSummaryStaticRowsAndHonestUnverified() {
        pinChineseForTesting()
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, spy, _) = makeModel(directory: temp.url)
        let p = validProfile()
        model.saveDraftProfile(p)

        // idle：SSH 层失败 → 摘要红、置位展开、点名失败行
        XCTAssertEqual(model.displaysDynamicMode, false, "automatic 配置在快照未生效前按静态展示")
        XCTAssertEqual(model.healthCheckRows.map(\.title), ["本地代理", "SSH 隧道", "远端代理"])
        XCTAssertEqual(model.healthSummary.title, "1 项检查未通过")
        XCTAssertEqual(model.healthSummary.failedTitles, ["SSH 隧道"])
        XCTAssertTrue(model.healthSummary.shouldExpandDetails)

        // connected + 远端未验证 → 2/3 已验证：unknown 绝不并入「通过」
        spy.emit(TunnelSnapshot(
            profileId: p.id, phase: .connected,
            localProxyVerified: true, sshProcessRunning: true, remoteProbeVerified: nil,
            lastRemoteProbeAt: nil, humanReadableDetail: "t"
        ))
        XCTAssertEqual(model.healthSummary.title, "2/3 项已验证")
        XCTAssertEqual(model.healthSummary.tone, .orange)
        XCTAssertFalse(model.healthSummary.shouldExpandDetails)
    }

    func testHealthSummaryDynamicModeRenamesRowsAndAddsHTTPAdapter() {
        pinChineseForTesting()
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, spy, _) = makeModel(directory: temp.url)
        var p = validProfile(name: "动态机")
        p.connectionMode = .reverseDynamic
        model.saveDraftProfile(p)

        XCTAssertTrue(model.displaysDynamicMode)
        XCTAssertEqual(
            model.healthCheckRows.map(\.title),
            ["Mac 网络出口", "SSH 隧道", "远端 SOCKS5", "HTTP 兼容入口"],
            "动态模式改用出口语义标题，且 HTTP 兼容入口默认计入"
        )

        // 全部已验证 → 绿「N 项检查通过」并带验证时间
        spy.emit(TunnelSnapshot(
            profileId: p.id, phase: .connected,
            localProxyVerified: nil, sshProcessRunning: true, remoteProbeVerified: true,
            lastRemoteProbeAt: Date(), humanReadableDetail: "t"
        ))
        XCTAssertEqual(model.healthSummary.title, "3/4 项已验证", "HTTP 入口未验证（notRequested）时不得全绿")
        XCTAssertEqual(model.healthSummary.tone, .orange)
    }

    // MARK: 导航（概览为首页：先看状态，再进配置）

    func testSettingsOpenOnOverviewTabFirst() {
        pinChineseForTesting()
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, _, _) = makeModel(directory: temp.url)
        XCTAssertEqual(SettingsTab.allCases.first, .overview, "概览必须是第一个分区")
        XCTAssertEqual(model.settingsTab, .overview, "设置窗口默认落在概览页")
        model.openSettings(tab: .servers)
        XCTAssertEqual(model.settingsTab, .servers)
    }

    // MARK: 保存 / 删除

    func testSaveDraftProfilePersistsAndSelects() throws {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, _, _) = makeModel(directory: temp.url)
        let p = validProfile(name: "新机器")
        model.saveDraftProfile(p)
        XCTAssertEqual(model.profiles.last?.id, p.id)
        XCTAssertEqual(model.currentProfileId, p.id)

        // 独立仓库重读：确认真实落盘
        let reloaded = try ProfileRepository(directoryURL: temp.url).load()
        XCTAssertEqual(reloaded.profiles.first?.name, "新机器")
    }

    func testDeleteProfileStopsTunnelAndFallsBack() {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, spy, _) = makeModel(directory: temp.url)
        let a = validProfile(name: "A")
        let b = ServerProfile(name: "B", host: "b.example.com", sshPort: 22, username: "u2", remotePort: 7891)
        model.saveDraftProfile(a)
        model.saveDraftProfile(b)
        model.selectProfile(b.id)
        spy.activeIDs = [b.id]

        model.deleteProfile(b.id)

        XCTAssertTrue(spy.disconnectCalls.contains(b.id), "删除活跃 profile 必须先断开")
        XCTAssertFalse(model.profiles.contains { $0.id == b.id })
        XCTAssertEqual(model.currentProfileId, a.id, "回退到剩余第一个")
    }

    // MARK: 连接前置校验

    func testInvalidProfileRejectedAtSaveAndConnect() {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, spy, _) = makeModel(directory: temp.url)

        // U06「拒绝保存」：非法配置不得落盘
        var bad = validProfile()
        bad.host = "bad host"
        let saved = model.saveDraftProfile(bad)
        XCTAssertFalse(saved, "非法配置必须拒绝保存")
        XCTAssertTrue(model.profiles.isEmpty, "非法配置不得进入列表")

        // U06「拒绝连接」：绕过 UI 注入非法配置时，连接前置校验拦截
        model.upsertProfile(bad)
        model.connect()
        XCTAssertTrue(spy.connectCalls.isEmpty, "校验失败不得发起连接")
        XCTAssertEqual(model.currentSnapshot.phase, .error)
        XCTAssertTrue(model.currentSnapshot.humanReadableDetail.contains("校验"))
    }

    func testRemotePortConflictDetected() {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, _, _) = makeModel(directory: temp.url)
        let a = validProfile(name: "A")
        model.saveDraftProfile(a)
        let b = ServerProfile(name: "B", host: a.host, sshPort: a.sshPort, username: "u2", remotePort: a.remotePort)
        XCTAssertNotNil(model.remotePortConflictDescription(for: b), "同主机同远程端口必须提示冲突")

        let c = ServerProfile(name: "C", host: "other.example.com", sshPort: 22, username: "u3", remotePort: a.remotePort)
        XCTAssertNil(model.remotePortConflictDescription(for: c), "不同主机同端口不冲突")
    }

    func testConnectPassesResolvedEndpointToService() {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, spy, detector) = makeModel(directory: temp.url)
        model.saveDraftProfile(validProfile())
        // 经检测协议注入已验证候选（ViewModel 在装配时已注册回调）
        var state = ProxyDetectionState()
        state.candidates = [
            ProxyCandidate(
                endpoint: LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP),
                capability: .verified
            ),
        ]
        detector.onStateChange?(state)
        XCTAssertEqual(model.detection.candidates.count, 1)

        model.connect()
        XCTAssertEqual(spy.connectCalls.count, 1)
        XCTAssertEqual(spy.connectCalls.first?.localEndpoint?.port, 7897)
        XCTAssertEqual(spy.connectCalls.first?.profile.host, "10.11.154.192")
    }

    // MARK: 事件应用与「需重连」提示

    func testUpsertWhileConnectedFlagsReconnect() {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, spy, _) = makeModel(directory: temp.url)
        let p = validProfile()
        model.saveDraftProfile(p)
        spy.emit(TunnelSnapshot(
            profileId: p.id, phase: .connected, localProxyVerified: true,
            sshProcessRunning: true, remoteProbeVerified: true,
            lastRemoteProbeAt: Date(), humanReadableDetail: "端到端验证通过"
        ))
        XCTAssertEqual(model.currentSnapshot.phase, .connected)

        var edited = p
        edited.remotePort = 7891
        model.upsertProfile(edited)

        XCTAssertEqual(model.snapshots[p.id]?.phase, .degraded, "参数变更后不保留 connected")
        XCTAssertTrue(model.snapshots[p.id]?.humanReadableDetail.contains("重连") ?? false)
    }

    // MARK: 手动端点（U05 优先级）

    func testApplyManualEndpointValidatesAndPersists() throws {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, _, _) = makeModel(directory: temp.url)
        let p = validProfile()
        model.saveDraftProfile(p)

        let bad = model.applyManualEndpoint(host: "0.0.0.0", port: 7897, protocol: .http)
        XCTAssertFalse(bad.isEmpty, "非回环地址必须报错")

        let ok = model.applyManualEndpoint(host: "127.0.0.1", port: 1080, protocol: .socks5)
        XCTAssertTrue(ok.isEmpty)
        XCTAssertEqual(model.currentProfile?.proxySelectionMode, .manual)
        XCTAssertEqual(model.currentProfile?.manualEndpoint?.port, 1080)

        let reloaded = try ProfileRepository(directoryURL: temp.url).load()
        XCTAssertEqual(reloaded.profiles.first?.proxySelectionMode, .manual, "手动模式真实落盘")
    }

    // MARK: 用户断开语义

    func testUserDisconnectRoutesToService() {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, spy, _) = makeModel(directory: temp.url)
        let p = validProfile()
        model.saveDraftProfile(p)
        model.connect()
        model.disconnect()
        XCTAssertEqual(spy.disconnectCalls, [p.id])
    }

    // MARK: 复制命令

    func testRemoteCommandTextReflectsVerification() {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, _, _) = makeModel(directory: temp.url)
        model.saveDraftProfile(validProfile())
        let text = model.remoteCommandText()
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("尚未通过") ?? false, "未验证时复制命令须带提醒")
    }

    func testDynamicCommandCopyDoesNotLabelSOCKSPortAsHTTP() {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, _, _) = makeModel(directory: temp.url)
        var profile = validProfile()
        profile.connectionMode = .reverseDynamic
        XCTAssertTrue(profile.httpAdapterEnabled, "Codex HTTP 兼容入口应默认开启")
        model.saveDraftProfile(profile)

        let bPlus = model.remoteCommandText()
        XCTAssertNotNil(model.remoteHTTPCompatibilityText())
        XCTAssertTrue(bPlus?.contains("HTTP_PROXY=http://127.0.0.1:7890") == true)
        XCTAssertTrue(bPlus?.contains("--socks5-hostname 127.0.0.1:17890") == true)
        XCTAssertFalse(bPlus?.contains("HTTP_PROXY=http://127.0.0.1:17890") == true)

        profile.httpAdapterEnabled = false
        model.upsertProfile(profile)
        let socksOnly = model.remoteCommandText()
        XCTAssertNil(model.remoteHTTPCompatibilityText(), "明确关闭适配器时不应生成 HTTP_PROXY 命令")
        XCTAssertTrue(socksOnly?.contains("--socks5-hostname 127.0.0.1:17890") == true)
        XCTAssertFalse(socksOnly?.contains("HTTP_PROXY=http://127.0.0.1:17890") == true)
    }

    // MARK: 本地代理动态感知（U15：端点变化 → 无缝切换 / 本地失败 → 主动重扫）

    /// 可脚本化检测器：测试直接推送检测状态（模拟 SCDynamicStore 变化后的重扫完成）。
    @MainActor
    final class ScriptedDetector: ProxyDetectorService {
        var onStateChange: (@MainActor (ProxyDetectionState) -> Void)?
        private(set) var detectCalls = 0
        func startObservingSystemChanges() -> Bool { true }
        func detect() { detectCalls += 1 }
        func push(_ state: ProxyDetectionState) { onStateChange?(state) }
    }

    private func verifiedState(port: Int, protocol proto: ProxyProtocol = .http) -> ProxyDetectionState {
        var state = ProxyDetectionState()
        state.candidates = [
            ProxyCandidate(
                endpoint: LocalProxyEndpoint(host: "127.0.0.1", port: port, protocol: `proto`, origin: .systemHTTP, verifiedAt: Date()),
                capability: .verified,
                note: "测试注入"
            )
        ]
        return state
    }

    /// 活跃静态转发的快照（effectiveMode = staticForward + 活跃端点）。
    private func activeStaticSnapshot(profile: ServerProfile, endpoint: LocalProxyEndpoint?) -> TunnelSnapshot {
        var snap = TunnelSnapshot.idle(profile.id)
        snap.phase = .connected
        snap.localProxyVerified = true
        snap.sshProcessRunning = true
        snap.remoteProbeVerified = true
        snap.effectiveMode = .staticForward
        snap.activeLocalEndpoint = endpoint
        snap.humanReadableDetail = "远端代理已验证（HTTP 200）"
        return snap
    }

    @discardableResult
    private func makeModelWithScriptedDetector(directory: URL) -> (model: AppViewModel, tunnel: TunnelSpy, detector: ScriptedDetector) {
        let spy = TunnelSpy()
        let detector = ScriptedDetector()
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: directory),
            settingsStore: AppSettingsStore(directoryURL: directory),
            tunnel: spy,
            proxyDetector: detector,
            logStore: LogStore(),
            secrets: InMemoryPasswordStore()
        )
        return (model, spy, detector)
    }

    func testProxyEndpointChangeRetargetsActiveStaticTunnel() async {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, spy, detector) = makeModelWithScriptedDetector(directory: temp.url)
        var profile = validProfile(name: "动态跟随")
        profile.connectionMode = .staticForward
        model.saveDraftProfile(profile)
        profile = model.profiles[0]

        // 建立活跃静态隧道：使用 7897 端点
        let old = LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP)
        spy.activeIDs.insert(profile.id)
        spy.emit(activeStaticSnapshot(profile: profile, endpoint: old))

        // 系统代理变化 → 重扫完成，新端点 7898（协议也变化）
        detector.push(verifiedState(port: 7898, protocol: .socks5))
        let called = await waitUntilMain { spy.retargetCalls.count == 1 }
        XCTAssertTrue(called, "端点变化应触发无缝切换")
        XCTAssertEqual(spy.retargetCalls.first?.endpoint.port, 7898)
        XCTAssertEqual(spy.retargetCalls.first?.endpoint.protocol, .socks5)
        XCTAssertEqual(spy.retargetCalls.first?.profileID, profile.id)

        // 相同端点的重复扫描（verifiedAt 变化但 id 不变）不得再次触发
        detector.push(verifiedState(port: 7898, protocol: .socks5))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(spy.retargetCalls.count, 1, "端点未变化时不得重复下发切换")
    }

    func testProxyEndpointChangeSkipsDynamicAndInactiveTunnels() async {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, spy, detector) = makeModelWithScriptedDetector(directory: temp.url)

        // 动态 SOCKS5 会话：不需要本地端点，不切换
        var dynamic = validProfile(name: "动态机")
        dynamic.connectionMode = .reverseDynamic
        model.saveDraftProfile(dynamic)
        dynamic = model.profiles[0]
        var dynSnap = TunnelSnapshot.idle(dynamic.id)
        dynSnap.phase = .connected
        dynSnap.sshProcessRunning = true
        dynSnap.remoteProbeVerified = true
        dynSnap.effectiveMode = .reverseDynamic
        spy.activeIDs.insert(dynamic.id)
        spy.emit(dynSnap)

        // 未连接的静态 profile：不切换
        let idle = validProfile(name: "闲置机")
        model.saveDraftProfile(idle)

        detector.push(verifiedState(port: 7898))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(spy.retargetCalls.isEmpty, "动态模式与未连接会话都不应触发切换")
    }

    func testLocalFailureTriggersDetectorRescan() async {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, spy, detector) = makeModelWithScriptedDetector(directory: temp.url)
        let profile = validProfile(name: "自愈机")
        model.saveDraftProfile(profile)
        let current = model.profiles[0]
        spy.activeIDs.insert(current.id)
        spy.emit(activeStaticSnapshot(profile: current, endpoint: nil))

        // 本地验证失败（degraded + localProxyVerified=false + SSH 存活）→ 主动重扫
        // （bootstrap 已调用过一次 detect，此处以差值断言）
        let detectCallsBefore = detector.detectCalls
        var failed = activeStaticSnapshot(profile: current, endpoint: nil)
        failed.phase = .degraded
        failed.localProxyVerified = false
        failed.humanReadableDetail = "本地健康检查完成：代理未通过验证"
        spy.emit(failed)
        XCTAssertEqual(detector.detectCalls, detectCallsBefore + 1, "本地失败应触发一次主动重扫")

        // 冷却窗口内的重复失败快照不重复触发
        spy.emit(failed)
        XCTAssertEqual(detector.detectCalls, detectCallsBefore + 1, "冷却窗口内不得重复重扫")
    }
}
