import XCTest
@testable import ProxyBridge

/// 记录调用的隧道服务替身。
@MainActor
final class TunnelSpy: TunnelService {
    var onEvent: (@MainActor (TunnelEvent) -> Void)?
    private(set) var connectCalls: [TunnelConfiguration] = []
    private(set) var disconnectCalls: [UUID] = []
    private(set) var healthCheckCalls: [UUID] = []
    var activeIDs: Set<UUID> = []

    func connect(configuration: TunnelConfiguration) {
        connectCalls.append(configuration)
    }

    func disconnect(profileID: UUID) {
        disconnectCalls.append(profileID)
    }

    func runHealthCheck(profileID: UUID) {
        healthCheckCalls.append(profileID)
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
            secrets: InMemoryPasswordStore(),
            isDemoMode: true
        )
        return (model, spy, detector)
    }

    /// 每个测试自建临时目录并在结束时清理（XCTest 的 setUp/tearDown 重写与 @MainActor 隔离不兼容）。
    private func withTempDir() -> TempDirectory {
        TempDirectory.make()
    }

    private func validProfile(name: String = "测试机") -> ServerProfile {
        ServerProfile(name: name, host: "10.11.154.192", sshPort: 20064, username: "sunyun", remotePort: 7890)
    }

    // MARK: 启动装配

    func testBootstrapEmptyStartsDetection() async {
        let temp = withTempDir()
        defer { temp.removeAll() }
        let (model, _, _) = makeModel(directory: temp.url)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertTrue(model.overallPresentation.title == "未配置")
        let gotCandidates = await waitUntilMain { !model.detection.candidates.isEmpty }
        XCTAssertTrue(gotCandidates, "Mock 检测器应产出候选（演示）")
        XCTAssertFalse(model.detection.limitations.isEmpty, "演示模式必须带限制说明")
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
        XCTAssertTrue(text?.contains("尚未验证") ?? false, "未验证时复制命令须带提醒")
    }
}
