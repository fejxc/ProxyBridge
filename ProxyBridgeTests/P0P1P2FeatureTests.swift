import XCTest
import CryptoKit
@testable import ProxyBridge

// MARK: - P0/P1/P2 功能测试

/// 主机指纹信任（TOFU）纯函数与状态机。
@MainActor
final class HostKeyTrustTests: XCTestCase {

    /// ssh-keyscan 输出样例（非 22 端口带 [host]:port 前缀）。
    static let sampleScan = """
    # 10.11.154.192:20064 SSH-2.0-OpenSSH_9.6
    [10.11.154.192]:20064 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
    [10.11.154.192]:20064 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
    [10.11.154.192]:20064 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD
    """

    func testParseDeduplicatesAndSortsPreferingEd25519() {
        let records = HostKeyTrustService.parseKeyScanOutput(Self.sampleScan)
        XCTAssertEqual(records.count, 2, "同算法重复行只保留首条，注释行忽略")
        XCTAssertEqual(records.first?.keyType, "ssh-ed25519", "ed25519 排在最前")
        XCTAssertEqual(records.first?.hostField, "[10.11.154.192]:20064")
        XCTAssertEqual(records.last?.keyType, "ssh-rsa")
    }

    func testFingerprintMatchesOpenSSHFormat() {
        let blob = "AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        let fingerprint = HostKeyTrustService.fingerprint(keyBlob: blob)
        XCTAssertNotNil(fingerprint)
        XCTAssertTrue(fingerprint?.hasPrefix("SHA256:") == true, "OpenSSH 展示格式")
        XCTAssertFalse(fingerprint?.contains("=") == true, "无 padding")
        // 同输入确定性 / 异输入区分
        XCTAssertEqual(fingerprint, HostKeyTrustService.fingerprint(keyBlob: blob))
        XCTAssertNotEqual(fingerprint, HostKeyTrustService.fingerprint(keyBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"))
        XCTAssertNil(HostKeyTrustService.fingerprint(keyBlob: "not-base64!!"), "非法 base64 返回 nil")
    }

    func testTrustAppendsWithIdempotence() throws {
        let dir = TempDirectory.make()
        defer { dir.removeAll() }
        let file = dir.url.appendingPathComponent("known_hosts")
        let service = HostKeyTrustService(knownHostsURL: file)
        let records = HostKeyTrustService.parseKeyScanOutput(Self.sampleScan)
        XCTAssertTrue(service.trust(records))
        let first = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(first.contains("ssh-ed25519"))
        // 幂等：再次写入不产生重复行
        XCTAssertTrue(service.trust(records))
        let second = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(first, second)
        // 追加新算法：只增加新行
        let extra = HostKeyRecord(hostField: "[10.11.154.192]:20064", keyType: "ecdsa-sha2-nistp256", keyBlob: Self.blobBase64, fingerprint: "SHA256:x")
        XCTAssertTrue(service.trust([extra]))
        let third = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(third.filter { $0 == "\n" }.count, first.filter { $0 == "\n" }.count + 1)
    }

    static let blobBase64 = "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABB1234"
}

/// 分类器：首次连接（可 TOFU）与密钥变化（危险，不给一键信任）严格区分。
final class HostKeyClassificationTests: XCTestCase {
    func testUnknownHostIsTofuEligible() {
        let stderr = "The authenticity of host 'x' can't be established.\r\nED25519 key fingerprint is SHA256:abc.\r\nHost key verification failed.\r\n"
        guard case .hostKeyUnknown = SSHErrorClassifier.classify(exitCode: 255, stderr: stderr) else {
            return XCTFail("未知主机应归 hostKeyUnknown（可应用内引导）")
        }
        let (phase, _) = SSHErrorClassifier.phaseAndDetail(for: .hostKeyUnknown(detail: "d"))
        XCTAssertEqual(phase, .authRequired, "仍为终态：等待用户动作")
    }

    func testChangedHostKeyIsNotTofuEligible() {
        let stderr = "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r\nHost key verification failed.\r\n"
        guard case .authRequired = SSHErrorClassifier.classify(exitCode: 255, stderr: stderr) else {
            return XCTFail("密钥变化必须走 authRequired（人工核对，不提供一键覆盖）")
        }
    }
}

/// 版本比较（更新检查的判定核心：绝不能误报）。
final class VersionComparisonTests: XCTestCase {
    func testSemanticOrdering() {
        XCTAssertTrue(Version.isNewer(candidate: "1.4.0", current: "1.3.0"))
        XCTAssertTrue(Version.isNewer(candidate: "1.10.0", current: "1.9.0"), "数值比较而非字典序")
        XCTAssertTrue(Version.isNewer(candidate: "2.0", current: "1.9.9"))
        XCTAssertFalse(Version.isNewer(candidate: "1.3.0", current: "1.3.0"))
        XCTAssertFalse(Version.isNewer(candidate: "1.2.9", current: "1.3.0"))
    }

    func testMalformedNeverReportsNewer() {
        XCTAssertFalse(Version.isNewer(candidate: "latest", current: "1.3.0"))
        XCTAssertFalse(Version.isNewer(candidate: "", current: "1.3.0"))
        XCTAssertFalse(Version.isNewer(candidate: "1.4.0", current: "dev"))
        XCTAssertTrue(Version.isValidVersion("1.4.0"))
        XCTAssertFalse(Version.isValidVersion("v1.4.0-rc1"))
    }
}

/// ~/.ssh/config 解析。
@MainActor
final class SSHConfigParserTests: XCTestCase {
    func testParsesCoreDirectives() {
        let config = """
        # 注释行
        Host gpu-lab
          HostName 10.11.154.192
          Port 20064
          User sunyun
          IdentityFile ~/.ssh/id_ed25519

        Host *
          ServerAliveInterval 30
        Host !broken
          HostName 1.2.3.4
        """
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1, "通配与否定模式不导入")
        let entry = entries[0]
        XCTAssertEqual(entry.alias, "gpu-lab")
        XCTAssertEqual(entry.hostName, "10.11.154.192")
        XCTAssertEqual(entry.port, 20064)
        XCTAssertEqual(entry.user, "sunyun")
        XCTAssertEqual(entry.identityFile, "~/.ssh/id_ed25519")
    }

    func testEqualsSeparatorAndCaseInsensitivity() {
        let config = "Host jump\n  hostname=jump.example.com\n  PORT=2222\n  user=ops\n"
        let entries = SSHConfigParser.parse(config)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].hostName, "jump.example.com")
        XCTAssertEqual(entries[0].port, 2222)
        XCTAssertEqual(entries[0].user, "ops")
    }

    func testImportSkipsInvalidAndDuplicates() {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let spy = TunnelSpy()
        let detector = MockProxyDetector()
        detector.simulatedLatency = 0.02
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: temp.url),
            settingsStore: AppSettingsStore(directoryURL: temp.url),
            tunnel: spy, proxyDetector: detector,
            logStore: LogStore(), secrets: InMemoryPasswordStore()
        )
        let existing = ServerProfile(name: "已有", host: "10.0.0.5", sshPort: 22, username: "u", remotePort: 7890)
        model.saveDraftProfile(existing)
        let imported = model.importSSHConfigEntries([
            SSHConfigEntry(alias: "gpu", hostName: "10.11.154.192", port: 20064, user: "sunyun", identityFile: "~/.ssh/id_ed25519"),
            SSHConfigEntry(alias: "dup", hostName: "10.0.0.5", port: 22, user: "u", identityFile: nil),   // 重复
            SSHConfigEntry(alias: "bad", hostName: "bad host!", port: 22, user: "u", identityFile: nil), // 非法
        ])
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(model.profiles.count, 2)
        let newProfile = model.profiles.first { $0.name == "gpu" }
        XCTAssertEqual(newProfile?.host, "10.11.154.192")
        XCTAssertEqual(newProfile?.authMode, .identityFile, "有 IdentityFile 的条目应设为私钥模式")
    }
}

/// AppViewModel 新功能流程（指纹引导 / 更新 / 防休眠语义）。
@MainActor
final class AppViewModelFeatureTests: XCTestCase {

    final class StubHostKeyTrust: HostKeyTrustProviding {
        var records: [HostKeyRecord] = []
        var trustWrites: [[HostKeyRecord]] = []
        func scan(host: String, port: Int) async -> [HostKeyRecord] { records }
        func trust(_ records: [HostKeyRecord]) -> Bool {
            trustWrites.append(records)
            return true
        }
    }

    final class StubUpdateChecker: UpdateChecking {
        var info: UpdateInfo?
        init(info: UpdateInfo?) { self.info = info }
        func latestRelease() async -> UpdateInfo? { info }
    }

    final class SpyPowerAssertion: PowerAssertionControlling {
        private(set) var acquireCalls = 0
        private(set) var releaseCalls = 0
        private var active = false
        func acquire(reason: String) -> Bool {
            acquireCalls += 1
            if active { return true }
            active = true
            return true
        }
        func release() {
            // 与真实 IOPMAssertionRelease 一致：未持有时的 release 是无害空操作
            guard active else { return }
            releaseCalls += 1
            active = false
        }
        var isActive: Bool { active }
    }

    private func makeModel(
        directory: URL,
        hostKey: StubHostKeyTrust? = nil,
        updater: StubUpdateChecker? = nil,
        power: SpyPowerAssertion? = nil
    ) -> (model: AppViewModel, tunnel: TunnelSpy, detector: MockProxyDetector, hostKey: StubHostKeyTrust?, power: SpyPowerAssertion?) {
        let spy = TunnelSpy()
        let detector = MockProxyDetector()
        detector.simulatedLatency = 0.02
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: directory),
            settingsStore: AppSettingsStore(directoryURL: directory),
            tunnel: spy, proxyDetector: detector,
            logStore: LogStore(), secrets: InMemoryPasswordStore(),
            hostKeyTrust: hostKey, updateChecker: updater, powerAssertion: power
        )
        return (model, spy, detector, hostKey, power)
    }

    private func hostKeySnapshot(profile: ServerProfile) -> TunnelSnapshot {
        var snap = TunnelSnapshot.idle(profile.id)
        snap.phase = .authRequired
        snap.sshProcessRunning = false
        snap.hostKeyNeedsTrust = true
        snap.humanReadableDetail = "首次连接该服务器：known_hosts 尚无记录"
        return snap
    }

    func testHostKeyTrustFlowWritesAndReconnects() async {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let stub = StubHostKeyTrust()
        stub.records = [HostKeyRecord(hostField: "[10.11.154.192]:20064", keyType: "ssh-ed25519", keyBlob: "AAAA", fingerprint: "SHA256:abc")]
        let (model, spy, _, hostKey, _) = makeModel(directory: temp.url, hostKey: stub)
        let profile = ServerProfile(name: "新机器", host: "10.11.154.192", sshPort: 20064, username: "sunyun", remotePort: 7890)
        model.saveDraftProfile(profile)
        let current = model.profiles[0]

        spy.emit(hostKeySnapshot(profile: current))
        XCTAssertNotNil(model.pendingHostKeyProfileId, "收到 hostKeyNeedsTrust 快照应登记待确认")

        model.requestHostKeyScan()
        let fetched = await waitUntilMain { model.hostKeyScan == .fetched(stub.records) }
        XCTAssertTrue(fetched, "扫描完成应进入 fetched：\(model.hostKeyScan)")

        let connectsBefore = spy.connectCalls.count
        model.confirmHostKeyAndReconnect()
        XCTAssertEqual(hostKey?.trustWrites.count, 1, "确认即写入 known_hosts")
        XCTAssertNil(model.pendingHostKeyProfileId, "确认后清除待确认状态")
        XCTAssertEqual(spy.connectCalls.count, connectsBefore + 1, "确认后自动重连")
    }

    func testUpdateCheckRespectsVersionAndManualFeedback() async {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let current = AppViewModel.currentVersion
        let newer = UpdateInfo(latestVersion: "999.0.0", releaseURL: URL(string: "https://example.com")!)
        let (model, _, _, _, _) = makeModel(directory: temp.url, updater: StubUpdateChecker(info: newer))
        await model.checkForUpdates(manual: false)
        XCTAssertNotNil(model.updateInfo, "更高版本应登记提醒")

        let same = UpdateInfo(latestVersion: current, releaseURL: URL(string: "https://example.com")!)
        let (model2, _, _, _, _) = makeModel(directory: temp.url, updater: StubUpdateChecker(info: same))
        await model2.checkForUpdates(manual: false)
        XCTAssertNil(model2.updateInfo, "相同版本不得误报更新")

        // 手动检查失败必须给出界面反馈（此前静默只写日志）
        let (model3, _, _, _, _) = makeModel(directory: temp.url, updater: StubUpdateChecker(info: nil))
        await model3.checkForUpdates(manual: true)
        if case .failed = model3.updateCheckUIState {} else {
            XCTFail("手动检查失败应进入 failed 状态，实际 \(model3.updateCheckUIState)")
        }
    }

    /// 发现新版本：系统通知每版本只发一次；界面提醒（updateInfo）持续保留。
    func testUpdateNotificationSentOncePerVersion() async {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        final class StubSystemServices: AppSystemIntegrating {
            var onSleep: (() -> Void)?
            var onWake: (() -> Void)?
            var onNetworkRestored: (() -> Void)?
            var loginState: LoginItemState = .disabled
            private(set) var updateNotifications: [String] = []
            func setLoginEnabled(_ enabled: Bool) async throws {}
            func notificationPermission(request: Bool) async throws -> NotificationPermission { .allowed }
            func postNotification(profileID: UUID, body: String) async throws {}
            func postUpdateNotification(version: String) async throws { updateNotifications.append(version) }
            func clearNotifications() {}
            func stopObserving() {}
        }
        let system = StubSystemServices()
        let newer = UpdateInfo(latestVersion: "999.0.0", releaseURL: URL(string: "https://example.com")!)
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: temp.url),
            settingsStore: AppSettingsStore(directoryURL: temp.url),
            tunnel: TunnelSpy(),
            proxyDetector: MockProxyDetector(),
            logStore: LogStore(),
            secrets: InMemoryPasswordStore(),
            systemServices: system,
            updateChecker: StubUpdateChecker(info: newer)
        )
        await model.checkForUpdates(manual: false)
        await model.checkForUpdates(manual: false) // 同版本重复检查
        let notified = await waitUntilMain { system.updateNotifications.count == 1 }
        XCTAssertTrue(notified, "同版本第二次检查不得重复通知，实际 \(system.updateNotifications)")
        XCTAssertNotNil(model.updateInfo, "界面横幅持续保留")
    }

    /// 远端端口冲突（旧 sshd 未释放）：窗口内自动重试，窗口过后停止并保持终态指引。
    func testRemoteBindConflictRetriesWithinWindowOnly() async {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let spy = TunnelSpy()
        let runtime = ManagedTunnelService(underlying: spy)
        runtime.retryBaseSeconds = 0.03
        runtime.maximumRetrySeconds = 0.05
        runtime.monitorTickSeconds = 0.02
        runtime.remoteBindConflictWindowSeconds = 0.3 // 极短窗口便于测试

        var profile = ServerProfile(name: "192服务器", host: "10.11.154.192", sshPort: 20064, username: "sunyun", remotePort: 7890)
        profile.reconnectEnabled = true
        runtime.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: nil))

        func emitConflict() {
            var snap = TunnelSnapshot.idle(profile.id)
            snap.phase = .error
            snap.sshProcessRunning = false
            snap.humanReadableDetail = "远端 127.0.0.1:17890 监听失败：端口可能被占用或服务器禁止转发。"
            spy.emit(snap)
        }

        emitConflict() // 第一次：进入重试
        let firstRetry = await waitUntilMain { spy.connectCalls.count >= 2 }
        XCTAssertTrue(firstRetry, "端口冲突在窗口内应自动重试，实际连接次数 \(spy.connectCalls.count)")

        try? await Task.sleep(nanoseconds: 400_000_000) // 超过 0.3s 窗口
        let countBefore = spy.connectCalls.count
        emitConflict() // 窗口已过：不再重试
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(spy.connectCalls.count, countBefore, "窗口过后仍冲突应停止自动重试（终态指引）")
        runtime.terminateAllSessions()
    }

    /// 本地 Relay 端口冲突（固定端口被占）同样限时自动重连。
    func testLocalRelayConflictRetriesWithinWindow() async {
        let spy = TunnelSpy()
        let runtime = ManagedTunnelService(underlying: spy)
        runtime.retryBaseSeconds = 0.03
        runtime.maximumRetrySeconds = 0.05
        runtime.monitorTickSeconds = 0.02
        runtime.remoteBindConflictWindowSeconds = 60 // 窗口内验证即可

        var profile = ServerProfile(name: "固定Relay", host: "10.0.0.7", sshPort: 22, username: "u", remotePort: 7890)
        profile.reconnectEnabled = true
        runtime.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: nil))
        let connectsBefore = spy.connectCalls.count

        var snap = TunnelSnapshot.idle(profile.id)
        snap.phase = .error
        snap.sshProcessRunning = false
        snap.humanReadableDetail = "本地 Relay 无法启动（端口可能被占用）：…（NSPOSIXErrorDomain…98）"
        spy.emit(snap)
        let retried = await waitUntilMain { spy.connectCalls.count == connectsBefore + 1 }
        XCTAssertTrue(retried, "本地 Relay 端口冲突应在窗口内自动重连")
        runtime.terminateAllSessions()
    }

    func testKeepAwakeFollowsSettingAndActiveTunnel() {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let power = SpyPowerAssertion()
        let (model, spy, _, _, spyPower) = makeModel(directory: temp.url, power: power)
        let profile = ServerProfile(name: "p", host: "10.0.0.9", sshPort: 22, username: "u", remotePort: 7890)
        model.saveDraftProfile(profile)
        let current = model.profiles[0]

        var snap = TunnelSnapshot.idle(current.id)
        snap.phase = .connected
        snap.sshProcessRunning = true
        spy.emit(snap)
        XCTAssertEqual(spyPower?.acquireCalls, 0, "默认关闭：活跃连接也不持断言")

        model.updateSettings { $0.keepAwakeWhileConnected = true }
        XCTAssertEqual(spyPower?.acquireCalls, 1, "开启后活跃连接立即持有")
        var idle = snap
        idle.phase = .idle
        idle.sshProcessRunning = false
        spy.emit(idle)
        XCTAssertEqual(spyPower?.releaseCalls, 1, "断开后释放")
    }

    /// 出口 IP 指纹（节点切换检测）：解析合法 IP、变化触发活跃隧道立即重验。
    func testEgressIPParsing() {
        XCTAssertEqual(CurlEgressIPProbe.parseIP("103.152.32.11\n"), "103.152.32.11")
        XCTAssertEqual(CurlEgressIPProbe.parseIP("2606:4700::6810:85e5"), "2606:4700::6810:85e5")
        XCTAssertNil(CurlEgressIPProbe.parseIP("<html>hello</html>"), "HTML 垃圾不误判")
        XCTAssertNil(CurlEgressIPProbe.parseIP("999.1.1.1"), "非法 IPv4 拒绝")
        XCTAssertNil(CurlEgressIPProbe.parseIP(""))
    }

    func testEgressChangeTriggersImmediateRecheck() async {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        final class ScriptedDetector: ProxyDetectorService {
            var onStateChange: (@MainActor (ProxyDetectionState) -> Void)?
            func startObservingSystemChanges() -> Bool { true }
            func detect() {}
        }
        let spy = TunnelSpy()
        let detector = ScriptedDetector()
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: temp.url),
            settingsStore: AppSettingsStore(directoryURL: temp.url),
            tunnel: spy, proxyDetector: detector,
            logStore: LogStore(), secrets: InMemoryPasswordStore()
        )
        let profile = ServerProfile(name: "节点机", host: "10.0.0.3", sshPort: 22, username: "u", remotePort: 7890)
        model.saveDraftProfile(profile)
        let current = model.profiles[0]
        spy.activeIDs.insert(current.id)

        func push(egress: String?) {
            var state = ProxyDetectionState()
            state.candidates = [ProxyCandidate(
                endpoint: LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP, verifiedAt: Date()),
                capability: .verified
            )]
            state.egressIP = egress
            detector.onStateChange?(state)
        }
        push(egress: "103.1.1.1") // 首次观测：只记录
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(spy.healthCheckCalls.count, 0, "首次观测不触发重验")

        push(egress: "45.2.2.2") // 节点切换：立即重验活跃隧道
        let rechecked = await waitUntilMain { spy.healthCheckCalls.contains(current.id) }
        XCTAssertTrue(rechecked, "出口变化应立即触发活跃隧道远端重验")

        push(egress: "45.2.2.2") // 未变化：不重复
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(spy.healthCheckCalls.count, 1, "出口未变化不得重复重验")
    }

    // MARK: - P0：单实例 / 孤儿清扫 / 应用内更新

    func testSingleInstanceLockIsExclusive() {
        // XCTest host 是 App 本身：AppDelegate 启动时可能已持锁（首次 acquire 可能 false）。
        // 断言互斥性本身：两次获取至多一次成功（严格单成功场景由冒烟 F19 独立进程验证）。
        let first = SingleInstanceGuard.acquire()
        let second = SingleInstanceGuard.acquire()
        XCTAssertFalse(first && second, "锁必须互斥：两次获取至多一次成功")
    }

    func testOrphanSweeperSignatureMatrix() {
        let tunnelArgs = ["-p", "20064", "-N", "-T", "-o", "ExitOnForwardFailure=yes", "sunyun@10.11.154.192"]
        XCTAssertTrue(LocalOrphanSweeper.matchesSignature(tunnelArgs), "本 App 隧道命令特征")
        XCTAssertFalse(LocalOrphanSweeper.matchesSignature(["-p", "22", "sunyun@host"]), "交互式 ssh（无 -N）不受影响")
        XCTAssertFalse(LocalOrphanSweeper.matchesSignature(["-N", "-o", "other"]), "缺 ExitOnForwardFailure 特征")
        // 自身进程不是孤儿（父进程非 launchd）
        XCTAssertFalse(LocalOrphanSweeper.isOrphan(pid: ProcessInfo.processInfo.processIdentifier, uid: getuid()))
    }

    func testSHA256ParsingAndVerify() throws {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let installer = DMGUpdateInstaller()
        // .sha256 文本解析（官方格式：<hex>  <文件名>）
        let digest = String(repeating: "ab", count: 32)
        XCTAssertEqual(DMGUpdateInstaller.parseSHA256Hex("\(digest)  ProxyBridge-1.4.4-universal.dmg\n"), digest)
        XCTAssertNil(DMGUpdateInstaller.parseSHA256Hex("not-a-hash file"), "非法摘要拒绝")
        XCTAssertNil(DMGUpdateInstaller.parseSHA256Hex(""), "空文本拒绝")
        // 真实文件校验：内容 → SHA256 → verify
        let file = temp.url.appendingPathComponent("payload.bin")
        try Data("proxybridge".utf8).write(to: file)
        let expected = SHA256.hash(data: Data("proxybridge".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(installer.verify(file: file, expectedHex: expected))
        XCTAssertFalse(installer.verify(file: file, expectedHex: String(repeating: "0", count: 64)))
    }

    /// 应用内更新状态机：下载失败/拿不到校验值 → 绝不安装；成功链 → relaunch。
    func testUpdateInstallFlowStates() async {
        final class StubInstaller: UpdateInstalling {
            var localFile: URL?
            var expected: String?
            var failDownload = false
            var failSHA = false
            var failVerify = false
            private(set) var installed: [URL] = []
            func download(url: URL, progress: @escaping (Double) -> Void) async -> URL? {
                if failDownload { return nil }
                localFile = FileManager.default.temporaryDirectory.appendingPathComponent("stub-\(UUID()).dmg")
                try? Data("dmg".utf8).write(to: localFile!)
                progress(1)
                return localFile
            }
            func fetchExpectedSHA256(url: URL) async -> String? { failSHA ? nil : expected }
            func verify(file: URL, expectedHex: String) -> Bool { !failVerify }
            func installAndRelaunch(dmg: URL) -> Bool { installed.append(dmg); return true }
        }
        let temp = TempDirectory.make()
        defer { temp.removeAll() }

        func make(_ installer: StubInstaller) async -> (AppViewModel, TunnelSpy) {
            let spy = TunnelSpy()
            let info = UpdateInfo(
                latestVersion: "999.0.0",
                releaseURL: URL(string: "https://example.com")!,
                dmgURL: URL(string: "https://example.com/x.dmg")!,
                sha256URL: URL(string: "https://example.com/x.dmg.sha256")!
            )
            let model = AppViewModel(
                profileStore: ProfileRepository(directoryURL: temp.url),
                settingsStore: AppSettingsStore(directoryURL: temp.url),
                tunnel: spy, proxyDetector: MockProxyDetector(),
                logStore: LogStore(), secrets: InMemoryPasswordStore(),
                updateChecker: StubUpdateChecker(info: info),
                updateInstaller: installer
            )
            // updateInfo 须经一次检查才会登记
            await model.checkForUpdates(manual: false)
            return (model, spy)
        }

        // 下载失败 → failed，不安装
        let bad = StubInstaller(); bad.failDownload = true; bad.expected = String(repeating: "a", count: 64)
        let (model1, _) = await make(bad)
        model1.downloadAndInstallUpdate()
        let failedState = await waitUntilMain {
            if case .failed = model1.updateInstallState { return true }
            return false
        }
        XCTAssertTrue(failedState)
        XCTAssertTrue(bad.installed.isEmpty)

        // 拿不到官方校验值 → 绝不自动安装（安全优先）
        let noSHA = StubInstaller(); noSHA.failSHA = true; noSHA.expected = String(repeating: "a", count: 64)
        let (model2, _) = await make(noSHA)
        model2.downloadAndInstallUpdate()
        _ = await waitUntilMain { if case .failed = model2.updateInstallState { return true }; return false }
        XCTAssertTrue(noSHA.installed.isEmpty, "缺校验值必须拒绝安装")

        // 成功链 → 安装调用 + relaunch 请求（非 /Applications 环境不重启但状态回 idle）
        let good = StubInstaller(); good.expected = String(repeating: "a", count: 64)
        let (model3, _) = await make(good)
        var relaunched = false
        model3.relaunchAfterUpdate = { relaunched = true }
        model3.downloadAndInstallUpdate()
        let done = await waitUntilMain { !good.installed.isEmpty && model3.updateInstallState == .idle }
        XCTAssertTrue(done, "成功链应完成安装")
        XCTAssertEqual(relaunched, Bundle.main.bundleURL.path.hasPrefix("/Applications/"))
    }

    func testLegacySettingsDecodeKeepsNewFieldDefaults() throws {
        // 旧版 settings.json（无新字段）不得判损坏，新字段取默认值
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let legacy = """
        {"launchAtLoginRequested":false,"showNotifications":true,"remoteCheckIntervalSeconds":30,"localCheckIntervalSeconds":15,"redactLogsOnCopy":false}
        """
        try Data(legacy.utf8).write(to: temp.url.appendingPathComponent("settings.json"))
        let store = AppSettingsStore(directoryURL: temp.url)
        let loaded = store.load()
        XCTAssertFalse(store.lastLoadWasCorrupted, "缺新字段不是损坏")
        XCTAssertEqual(loaded.remoteCheckIntervalSeconds, 30, "旧字段保留")
        XCTAssertTrue(loaded.checkForUpdates, "新字段默认开")
        XCTAssertFalse(loaded.keepAwakeWhileConnected)
        XCTAssertEqual(loaded.language, .system)
    }
}
