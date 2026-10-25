import XCTest
@testable import ProxyBridge

/// 远端端口残留诊断/清理：脚本构建、输出解析、分类与 AppViewModel 集成。
@MainActor
final class RemoteJanitorTests: XCTestCase {

    // MARK: - 解析与分类（纯函数）

    static let sampleOutput = """
    PBJANITOR|17890|2206590|sshd|0|sshd: root@notty
    PBJANITOR|7890|2206110|privoxy|0|/usr/sbin/privoxy --no-daemon /root/.cache/proxybridge/privoxy-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/config
    PBJANITOR|7891|1900|python3|1|python3 -m http.server 7891
    PBJANITOR|17892|3000|nc|0|nc -l 17892
    噪音行不解析
    PBJANITOR|abc|def|bad|0|格式错误
    """

    func testParseInspectExtractsHoldings() {
        let holdings = RemoteJanitorScript.parseInspect(Self.sampleOutput)
        XCTAssertEqual(holdings.count, 4, "噪音行与格式错误行忽略")
        XCTAssertEqual(holdings[0].port, 17890)
        XCTAssertEqual(holdings[0].pid, 2_206_590)
        XCTAssertEqual(holdings[1].comm, "privoxy")
    }

    func testKindClassificationPrioritizesEstablished() {
        let holdings = RemoteJanitorScript.parseInspect(Self.sampleOutput)
        XCTAssertEqual(holdings[0].kind, .staleSSHD, "无活连接的 sshd → 僵尸可清理")
        XCTAssertEqual(holdings[1].kind, .ownedPrivoxy, "带 App 配置目录的 Privoxy → 自家孤儿")
        XCTAssertEqual(holdings[2].kind, .busy, "有活连接 → 一律不清理（即使可能是自家）")
        XCTAssertEqual(holdings[3].kind, .thirdParty, "陌生进程 → 只报告")
        XCTAssertTrue(holdings[0].kind.isCleanable)
        XCTAssertTrue(holdings[1].kind.isCleanable)
        XCTAssertFalse(holdings[2].kind.isCleanable)
        XCTAssertFalse(holdings[3].kind.isCleanable)
    }

    static let statefulOutput = """
    PBJANITOR|7890|9001|sshd|0|sshd: root@notty|0C
    PBJANITOR|7890|0|kernel|0|TIME_WAIT×3|06
    PBJANITOR|17890|9002|sshd|1|sshd: root@pts|01
    PBJANITOR|17890|9002|sshd|1|sshd: root@pts|0A
    """

    func testParseInspectFullStateScan() {
        let holdings = RemoteJanitorScript.parseInspect(Self.statefulOutput)
        XCTAssertEqual(holdings.count, 3, "CLOSE_WAIT/TIME_WAIT/LISTEN 各一条；同端口同进程去重为一条")
        XCTAssertEqual(holdings[0].state, "0C")
        XCTAssertEqual(holdings[0].kind, .staleSSHD, "CLOSE_WAIT 的旧 sshd 子进程 → 可精准清理")
        XCTAssertTrue(holdings[0].kind.isCleanable)
        XCTAssertEqual(holdings[1].state, "06")
        XCTAssertEqual(holdings[1].kind, .residual, "TIME_WAIT 为内核持有 → 只报告不可清理")
        XCTAssertFalse(holdings[1].kind.isCleanable)
        XCTAssertEqual(holdings[2].state, "0A", "同 pid 的 LISTEN 行优先于 ESTABLISHED 行")
        XCTAssertEqual(holdings[2].kind, .busy)
    }

    func testLegacySixColumnStillParsesAsListening() {
        let holdings = RemoteJanitorScript.parseInspect(Self.sampleOutput)
        XCTAssertTrue(holdings.allSatisfy { $0.state == "0A" }, "6 列旧格式默认 LISTEN")
    }

    func testKindActiveSSHDNeverCleanable() {
        let live = RemotePortHolding(port: 17890, pid: 123, comm: "sshd", established: true, cmdline: "sshd: root@notty")
        XCTAssertEqual(live.kind, .busy, "活 sshd（另一条正常隧道）绝不清理")
    }

    func testScriptsContainOnlyNumericPIDsAndMarkers() {
        let inspect = RemoteJanitorScript.inspectScript(ports: [17890, 7890])
        XCTAssertTrue(inspect.contains("17890") && inspect.contains("7890"))
        XCTAssertTrue(inspect.contains(RemoteJanitorScript.marker))
        XCTAssertTrue(inspect.contains("$10 \":\" $4"), "诊断须读取每个 socket 的状态")
        XCTAssertFalse(inspect.contains("$4==\"0A\""), "只查 LISTEN 会漏掉旧转发连接")
        XCTAssertTrue(inspect.contains("TIME_WAIT×"), "内核残留应单独报告")
        XCTAssertFalse(inspect.contains("; rm"), "诊断脚本只读，不包含破坏性命令")
        let clean = RemoteJanitorScript.cleanScript(
            targets: [
                RemoteCleanTarget(pid: 111, expectedCommPrefix: "sshd"),
                RemoteCleanTarget(pid: 222, expectedCommPrefix: "privoxy"),
            ],
            ports: [17890])
        XCTAssertTrue(clean.contains("kill \"$pid\""))
        XCTAssertTrue(clean.contains("/proc/$pid/comm"), "kill 前须按 /proc/<pid>/comm 复核，防 PID 复用误杀")
        XCTAssertTrue(clean.contains("111:sshd") && clean.contains("222:privoxy"), "预期进程名前缀须随目标下发")
        XCTAssertTrue(clean.contains("PBJANITOR|FREED") || clean.contains("FREED"))
    }

    func testCleanableCommPrefixOnlyForCleanableKinds() {
        XCTAssertEqual(RemotePortHolding.Kind.staleSSHD.cleanableCommPrefix, "sshd")
        XCTAssertEqual(RemotePortHolding.Kind.ownedPrivoxy.cleanableCommPrefix, "privoxy")
        XCTAssertNil(RemotePortHolding.Kind.busy.cleanableCommPrefix, "不可清的 kind 无前缀 → 脚本不会 kill")
        XCTAssertNil(RemotePortHolding.Kind.residual.cleanableCommPrefix)
        XCTAssertNil(RemotePortHolding.Kind.thirdParty.cleanableCommPrefix)
    }

    func testParseCleanOutcome() {
        let outcome = RemoteJanitorScript.parseClean("PBJANITOR|FREED|17890\nPBJANITOR|STILL|7890\nnoise")
        XCTAssertEqual(outcome.freedPorts, [17890])
        XCTAssertEqual(outcome.stillHeldPorts, [7890])
        XCTAssertFalse(outcome.allFreed)
        XCTAssertTrue(RemoteJanitorScript.parseClean("PBJANITOR|FREED|17890").allFreed)
    }

    // MARK: - AppViewModel 集成（注入替身）

    final class StubJanitor: RemoteJanitorProviding {
        var holdings: [RemotePortHolding]?
        var outcome: RemoteCleanOutcome?
        private(set) var inspectCalls = 0
        private(set) var cleanTargets: [RemotePortHolding] = []
        func inspect(profile: ServerProfile, ports: [Int], password: String?) async -> [RemotePortHolding]? {
            inspectCalls += 1
            return holdings
        }
        func clean(profile: ServerProfile, targets: [RemotePortHolding], password: String?) async -> RemoteCleanOutcome? {
            cleanTargets = targets
            return outcome
        }
    }

    func testConflictSnapshotTriggersInspectionAndCleanReconnects() async {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let janitor = StubJanitor()
        janitor.holdings = [
            RemotePortHolding(port: 17890, pid: 2206590, comm: "sshd", established: false, cmdline: "sshd: root@notty"),
            RemotePortHolding(port: 7890, pid: 2206110, comm: "privoxy", established: false,
                              cmdline: "/usr/sbin/privoxy /root/.cache/proxybridge/privoxy-tok/config"),
        ]
        janitor.outcome = RemoteCleanOutcome(freedPorts: [17890, 7890], stillHeldPorts: [])
        let spy = TunnelSpy()
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: temp.url),
            settingsStore: AppSettingsStore(directoryURL: temp.url),
            tunnel: spy,
            proxyDetector: MockProxyDetector(),
            logStore: LogStore(),
            secrets: InMemoryPasswordStore(),
            remoteJanitor: janitor
        )
        let profile = ServerProfile(name: "192服务器", host: "10.11.154.192", sshPort: 20064, username: "sunyun", remotePort: 17891)
        model.saveDraftProfile(profile)
        let current = model.profiles[0]

        // 模拟端口绑定冲突快照 → 自动诊断
        var snap = TunnelSnapshot.idle(current.id)
        snap.phase = .error
        snap.sshProcessRunning = false
        snap.humanReadableDetail = "远端 127.0.0.1:17890 监听失败：端口可能被占用或服务器禁止转发。"
        spy.emit(snap)
        let diagnosed = await waitUntilMain {
            if case .report(let holdings)? = model.portConflict?.state { return holdings.count == 2 }
            return false
        }
        XCTAssertTrue(diagnosed, "冲突快照应触发自动诊断并展示报告，实际 \(String(describing: model.portConflict?.state))")
        XCTAssertEqual(janitor.inspectCalls, 1)

        // 用户确认清理 → 仅清理可清对象 → 释放后自动重连
        let connectsBefore = spy.connectCalls.count
        model.cleanRemoteResidueAndReconnect()
        let reconnected = await waitUntilMain { spy.connectCalls.count == connectsBefore + 1 }
        XCTAssertTrue(reconnected, "清理成功后应自动重连")
        XCTAssertEqual(janitor.cleanTargets.map(\.pid), [2_206_590, 2_206_110], "只清理僵尸 sshd 与自家 Privoxy")
        XCTAssertNil(model.portConflict, "清理完成后撤卡")
    }

    func testUnavailableDiagnosisWhenSSHUnreachable() async {
        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let janitor = StubJanitor()
        janitor.holdings = nil // SSH 不可达
        let spy = TunnelSpy()
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: temp.url),
            settingsStore: AppSettingsStore(directoryURL: temp.url),
            tunnel: spy,
            proxyDetector: MockProxyDetector(),
            logStore: LogStore(),
            secrets: InMemoryPasswordStore(),
            remoteJanitor: janitor
        )
        let profile = ServerProfile(name: "s", host: "10.0.0.1", sshPort: 22, username: "u", remotePort: 17891)
        model.saveDraftProfile(profile)
        let current = model.profiles[0]
        var snap = TunnelSnapshot.idle(current.id)
        snap.phase = .error
        snap.humanReadableDetail = "远端 127.0.0.1:17890 监听失败：端口可能被占用或服务器禁止转发。"
        spy.emit(snap)
        let unavailable = await waitUntilMain {
            if case .unavailable? = model.portConflict?.state { return true }
            return false
        }
        XCTAssertTrue(unavailable, "SSH 不可达应如实报告，不猜测")
    }
}
