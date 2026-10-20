import Foundation
import CryptoKit

// P0/P1/P2 功能冒烟检查（本地 CLI 可执行；与 XCTest 互补，覆盖生产装配链路）

extension SmokeMain {

    /// 自包含隧道替身：记录系统断开/重连语义（网络恢复与模式升级用）。
    /// connectOutcome：注入 connect 的即时结局快照（如端口冲突 error）；nil = 默认 connected。
    final class FeatureTunnelSpy: TunnelService {
        var onEvent: (@MainActor (TunnelEvent) -> Void)?
        var connectOutcome: TunnelSnapshot?
        private let lock = NSLock()
        private var connectLog: [TunnelConfiguration] = []
        private var systemDisconnects: [String] = []
        private var activeIDs: Set<UUID> = []
        func connect(configuration: TunnelConfiguration) {
            lock.lock(); connectLog.append(configuration); activeIDs.insert(configuration.profile.id); lock.unlock()
            if let outcome = connectOutcome {
                onEvent?(.snapshot(outcome))
                return
            }
            var snap = TunnelSnapshot.idle(configuration.profile.id)
            snap.phase = .connected
            snap.sshProcessRunning = true
            snap.remoteProbeVerified = true
            onEvent?(.snapshot(snap))
        }
        func disconnect(profileID: UUID) {
            lock.lock(); activeIDs.remove(profileID); lock.unlock()
            onEvent?(.snapshot(.idle(profileID)))
        }
        func disconnectForSystemReason(profileID: UUID, reason: String) {
            lock.lock(); systemDisconnects.append(reason); activeIDs.remove(profileID); lock.unlock()
            onEvent?(.snapshot(.idle(profileID)))
        }
        func runHealthCheck(profileID: UUID) {}
        func isActive(profileID: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return activeIDs.contains(profileID) }
        func terminateAllSessions() { lock.lock(); activeIDs.removeAll(); lock.unlock() }
        func submitPassword(profileID: UUID, password: String, remember: Bool) {}
        func cancelPasswordPrompt(profileID: UUID) {}
        var connects: [TunnelConfiguration] { lock.lock(); defer { lock.unlock() }; return connectLog }
        var systemReasons: [String] { lock.lock(); defer { lock.unlock() }; return systemDisconnects }
    }

    @MainActor
    static func featureChecks() async {
        // F01 分类器：未知主机（TOFU）vs 密钥变化（不提供一键信任）
        let unknown = SSHErrorClassifier.classify(exitCode: 255, stderr: "Host key verification failed.\r\n")
        if case .hostKeyUnknown = unknown { check("F01a", "未知主机归类为可引导 TOFU", true) }
        else { check("F01a", "未知主机归类为可引导 TOFU", false) }
        let changed = SSHErrorClassifier.classify(
            exitCode: 255,
            stderr: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\r\nHost key verification failed.\r\n"
        )
        if case .authRequired = changed { check("F01b", "密钥变化不得提供一键信任（潜在劫持信号）", true) }
        else { check("F01b", "密钥变化不得提供一键信任（潜在劫持信号）", false) }

        // F02 keyscan 解析 + 指纹格式 + trust 幂等（真实临时文件）
        let scan = """
        # host SSH-2.0-OpenSSH_9.6
        [10.11.154.192]:20064 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        [10.11.154.192]:20064 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
        [10.11.154.192]:20064 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD
        """
        let records = HostKeyTrustService.parseKeyScanOutput(scan)
        check("F02a", "keyscan 解析去重并 ed25519 优先",
              records.count == 2 && records.first?.keyType == "ssh-ed25519" && records.first?.hostField == "[10.11.154.192]:20064")
        check("F02b", "指纹为 SHA256: 且无 padding",
              records.allSatisfy { $0.fingerprint.hasPrefix("SHA256:") && !$0.fingerprint.contains("=") })
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyBridgeSmokeHK-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("known_hosts")
        let trust = HostKeyTrustService(knownHostsURL: file)
        check("F02c", "trust 写入 known_hosts 并幂等",
              trust.trust(records) && trust.trust(records)
                && ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count == 2)

        // F03 版本比较（不误报）
        check("F03", "语义化版本比较：1.10.0>1.9.0、相同不报、畸形不报",
              Version.isNewer(candidate: "1.10.0", current: "1.9.0")
                && !Version.isNewer(candidate: "1.3.0", current: "1.3.0")
                && !Version.isNewer(candidate: "latest", current: "1.3.0"))

        // F04 ssh config 解析（= 分隔、大小写、通配跳过）
        let config = """
        Host gpu
          HostName 10.11.154.192
          Port=20064
          user sunyun
          IdentityFile ~/.ssh/id_ed25519
        Host *
          ForwardAgent yes
        """
        let entries = SSHConfigParser.parse(config)
        check("F04", "ssh config 解析核心指令并跳过通配",
              entries.count == 1 && entries[0].hostName == "10.11.154.192"
                && entries[0].port == 20064 && entries[0].user == "sunyun"
                && entries[0].identityFile == "~/.ssh/id_ed25519")

        // F05 旧 settings.json 兼容
        let sdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyBridgeSmokeS-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sdir) }
        try? Data("{\"showNotifications\":false,\"remoteCheckIntervalSeconds\":30}".utf8)
            .write(to: sdir.appendingPathComponent("settings.json"))
        let store = AppSettingsStore(directoryURL: sdir)
        let settings = store.load()
        check("F05", "旧 settings 缺新字段不判损坏且取默认",
              !store.lastLoadWasCorrupted && settings.showNotifications == false
                && settings.remoteCheckIntervalSeconds == 30 && settings.checkForUpdates
                && settings.language == .system)

        // F06 ManagedTunnelService 网络恢复：退避中的立即重连、活跃的回收重建、未开自动重连的不动
        await networkRestorationChecks()

        // F07 动态→静态回升（连续两次验证同一端点才升级）
        await upgradeChecks()

        // F08 L10n：三态显式断言绝对值（与宿主系统语言无关）
        L10n.apply(.chinese)
        let zh = TunnelStatusPresentation.overall(for: TunnelSnapshot.idle(UUID()))
        L10n.apply(.english)
        let en = TunnelStatusPresentation.overall(for: TunnelSnapshot.idle(UUID()))
        L10n.apply(.chinese)
        check("F08", "L10n：中文原样、英文查表、回退安全",
              zh.title == "未连接" && en.title == "Not connected"
                && L10n.t("不存在的句子") == "不存在的句子")

        // F09 安装指引：不含危险命令，含主流包管理器
        let curlHint = RemoteCommandTemplate.installHintCommands(component: .curl)
        let privoxyHint = RemoteCommandTemplate.installHintCommands(component: .privoxy)
        let dangerous = ["rm -rf", "curl | sh", "wget", "sudo su"]
        check("F09", "安装指引覆盖 apt/dnf 且无危险命令",
              curlHint.contains("apt-get install -y curl") && curlHint.contains("dnf install -y curl")
                && privoxyHint.contains("privoxy")
                && !dangerous.contains { curlHint.contains($0) || privoxyHint.contains($0) })

        // F10/F11 远端端口冲突：窗口内自动重试，窗口后停止
        await bindConflictChecks()

        // F12–F14 远端残留诊断清理
        await janitorChecks()

        // F16 日志落盘：真实文件写入、脱敏、轮转、内存构造不触碰磁盘
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyBridgeSmokeLog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }
        let persistStore = LogStore.live(directoryURL: logDir)
        persistStore.append(raw: "sunyun@10.11.154.192 Bearer abcdef1234567890", level: .warning)
        let logFile = logDir.appendingPathComponent("app.log")
        let logText = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        persistStore.fileSizeLimit = 64
        persistStore.append(raw: "rotate-trigger", level: .info)
        let rotatedText = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let memoryStore = LogStore()
        memoryStore.append(raw: "memory-only", level: .info)
        check("F16", "日志落盘：脱敏写入真实文件、超限轮转归档、内存构造不触碰磁盘",
              logText.contains("10.11.154.192") && !logText.contains("abcdef1234567890")
                && FileManager.default.fileExists(atPath: logDir.appendingPathComponent("app.log.1").path)
                && rotatedText.contains("rotate-trigger")
                && memoryStore.fileURL == nil)

        // F17 出口 IP 指纹：解析 + 真实 curl（无代理端口 → 如实 nil，不猜测）
        check("F17", "出口 IP 解析：IPv4/IPv6 合法、HTML/非法值拒绝",
              CurlEgressIPProbe.parseIP("103.152.32.11\n") == "103.152.32.11"
                && CurlEgressIPProbe.parseIP("2606:4700::6810:85e5") == "2606:4700::6810:85e5"
                && CurlEgressIPProbe.parseIP("<html>x</html>") == nil
                && CurlEgressIPProbe.parseIP("999.1.1.1") == nil)
        let egressProbe = CurlEgressIPProbe(connectTimeoutSeconds: 1, maxTimeSeconds: 3)
        let refused = await egressProbe.probe(host: "127.0.0.1", port: 1, protocol: .http)
        check("F17b", "真实 curl：出口探测失败返回 nil（如实不猜测）", refused == nil)

        // F18 出口变化 → 活跃隧道立即重验（节点切换全自动闭环）
        await egressChangeChecks()

        // F19 单实例锁（真实 flock：第二次获取必须失败）
        check("F19", "单实例锁互斥（双开被拒，崩溃自动释放由内核保证）",
              SingleInstanceGuard.acquire() && !SingleInstanceGuard.acquire())

        // F20 孤儿 ssh 清扫特征（交互式 ssh 与无关进程不受影响）
        check("F20", "孤儿 ssh 特征匹配：仅本 App 的 -N + ExitOnForwardFailure 组合",
              LocalOrphanSweeper.matchesSignature(["-p", "20064", "-N", "-T", "-o", "ExitOnForwardFailure=yes", "u@h"])
                && !LocalOrphanSweeper.matchesSignature(["-p", "22", "u@h"])
                && !LocalOrphanSweeper.matchesSignature(["-N", "-o", "ServerAliveInterval=30", "u@h"])
                && !LocalOrphanSweeper.isOrphan(pid: ProcessInfo.processInfo.processIdentifier, uid: getuid()))

        // F21 更新安装：SHA 文本解析 + 真实文件校验
        let hex = String(repeating: "ab", count: 32)
        let payloadFile = FileManager.default.temporaryDirectory.appendingPathComponent("pb-smoke-\(UUID()).bin")
        try? Data("payload".utf8).write(to: payloadFile)
        defer { try? FileManager.default.removeItem(at: payloadFile) }
        let realDigest = SHA256.hash(data: Data("payload".utf8)).map { String(format: "%02x", $0) }.joined()
        let installer = DMGUpdateInstaller()
        check("F21", "更新校验：官方 .sha256 解析 + 真实摘要匹配/拒绝",
              DMGUpdateInstaller.parseSHA256Hex("\(hex)  ProxyBridge-x.dmg") == hex
                && DMGUpdateInstaller.parseSHA256Hex("bad file") == nil
                && installer.verify(file: payloadFile, expectedHex: realDigest)
                && !installer.verify(file: payloadFile, expectedHex: hex))
    }

    @MainActor
    private static func egressChangeChecks() async {
        final class ScriptedDetector: ProxyDetectorService {
            var onStateChange: (@MainActor (ProxyDetectionState) -> Void)?
            func startObservingSystemChanges() -> Bool { true }
            func detect() {}
        }
        final class CountingTunnel: TunnelService {
            var onEvent: (@MainActor (TunnelEvent) -> Void)?
            private let lock = NSLock()
            private var checks: [UUID] = []
            var active: Set<UUID> = []
            func connect(configuration: TunnelConfiguration) { active.insert(configuration.profile.id) }
            func disconnect(profileID: UUID) { active.remove(profileID) }
            func runHealthCheck(profileID: UUID) {
                lock.lock(); checks.append(profileID); lock.unlock()
            }
            func isActive(profileID: UUID) -> Bool { active.contains(profileID) }
            func terminateAllSessions() { active.removeAll() }
            func submitPassword(profileID: UUID, password: String, remember: Bool) {}
            func cancelPasswordPrompt(profileID: UUID) {}
            var healthChecks: [UUID] { lock.lock(); defer { lock.unlock() }; return checks }
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyBridgeSmokeEg-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = CountingTunnel()
        let detector = ScriptedDetector()
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: dir),
            settingsStore: AppSettingsStore(directoryURL: dir),
            tunnel: spy, proxyDetector: detector,
            logStore: LogStore(), secrets: InMemoryPasswordStore()
        )
        let profile = ServerProfile(name: "节点机", host: "10.0.0.3", sshPort: 22, username: "u", remotePort: 7890)
        model.saveDraftProfile(profile)
        let current = model.profiles[0]
        spy.active.insert(current.id)

        func push(egress: String?) {
            var state = ProxyDetectionState()
            state.candidates = [ProxyCandidate(
                endpoint: LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP, verifiedAt: Date()),
                capability: .verified
            )]
            state.egressIP = egress
            detector.onStateChange?(state)
        }
        push(egress: "103.1.1.1")
        try? await Task.sleep(nanoseconds: 150_000_000)
        let firstQuiet = spy.healthChecks.isEmpty
        push(egress: "45.2.2.2")
        let rechecked = await waitSmokeUntil { spy.healthChecks.contains(current.id) }
        push(egress: "45.2.2.2")
        try? await Task.sleep(nanoseconds: 150_000_000)
        check("F18", "出口 IP 变化（节点切换）→ 活跃隧道立即重验；首次与未变化不触发",
              firstQuiet && rechecked && spy.healthChecks.count == 1)
    }

    @MainActor
    private static func janitorChecks() async {
        // F12 解析与分类（活连接优先，绝不误杀）
        let sample = """
        PBJANITOR|17890|2206590|sshd|0|sshd: root@notty
        PBJANITOR|7890|2206110|privoxy|0|/usr/sbin/privoxy /root/.cache/proxybridge/privoxy-tok/config
        PBJANITOR|17890|3000|sshd|1|sshd: root@notty
        PBJANITOR|9999|4000|nginx|0|nginx: master
        """
        let holdings = RemoteJanitorScript.parseInspect(sample)
        check("F12", "诊断解析与分类：僵尸 sshd/自家 Privoxy 可清，活连接与他人进程不动",
              holdings.count == 4
                && holdings[0].kind == .staleSSHD && holdings[0].kind.isCleanable
                && holdings[1].kind == .ownedPrivoxy && holdings[1].kind.isCleanable
                && holdings[2].kind == .busy && !holdings[2].kind.isCleanable
                && holdings[3].kind == .thirdParty && !holdings[3].kind.isCleanable)

        // F13 脚本通过本机 POSIX shell 语法检查（生产将在 Linux 执行，语法同源）
        func shellParses(_ script: String) -> Bool {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyBridge-janitor-\(UUID()).sh")
            defer { try? FileManager.default.removeItem(at: url) }
            do { try Data(script.utf8).write(to: url) } catch { return false }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n", url.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        check("F13", "远端诊断/清理脚本通过 POSIX shell 语法检查",
              shellParses(RemoteJanitorScript.inspectScript(ports: [17890, 7890]))
                && shellParses(RemoteJanitorScript.cleanScript(pids: [111, 222], ports: [17890])))
        check("F13b", "清理结果解析", RemoteJanitorScript.parseClean("PBJANITOR|FREED|17890\nPBJANITOR|STILL|7890")
                == RemoteCleanOutcome(freedPorts: [17890], stillHeldPorts: [7890]))

        // F14 集成：冲突快照自动诊断 → 确认清理 → 自动重连（替身注入）
        final class SmokeJanitor: RemoteJanitorProviding {
            var holdings: [RemotePortHolding]? = [
                RemotePortHolding(port: 17890, pid: 2206590, comm: "sshd", established: false, cmdline: "sshd: root@notty"),
                RemotePortHolding(port: 7890, pid: 2206110, comm: "privoxy", established: false,
                                  cmdline: "/usr/sbin/privoxy /root/.cache/proxybridge/privoxy-tok/config"),
            ]
            var outcome: RemoteCleanOutcome? = RemoteCleanOutcome(freedPorts: [17890, 7890], stillHeldPorts: [])
            func inspect(profile: ServerProfile, ports: [Int], password: String?) async -> [RemotePortHolding]? { holdings }
            func clean(profile: ServerProfile, targets: [RemotePortHolding], password: String?) async -> RemoteCleanOutcome? { outcome }
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyBridgeSmokeJan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let janitor = SmokeJanitor()
        let spy = FeatureTunnelSpy()
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: dir),
            settingsStore: AppSettingsStore(directoryURL: dir),
            tunnel: spy, proxyDetector: MockProxyDetector(),
            logStore: LogStore(), secrets: InMemoryPasswordStore(),
            remoteJanitor: janitor
        )
        var profile = ServerProfile(name: "192", host: "10.11.154.192", sshPort: 20064, username: "sunyun", remotePort: 7890)
        profile.connectionMode = .reverseDynamic
        model.saveDraftProfile(profile)
        profile = model.profiles[0]
        var snap = TunnelSnapshot.idle(profile.id)
        snap.phase = .error
        snap.sshProcessRunning = false
        snap.humanReadableDetail = "远端 127.0.0.1:17890 监听失败：端口可能被占用或服务器禁止转发。"
        spy.onEvent?(.snapshot(snap))
        let reported = await waitSmokeUntil {
            if case .report(let list)? = model.portConflict?.state { return list.count == 2 }
            return false
        }
        check("F14a", "端口冲突自动触发 SSH 诊断并报告占用者", reported)
        let before = spy.connects.count
        model.cleanRemoteResidueAndReconnect()
        let reconnected = await waitSmokeUntil { spy.connects.count == before + 1 }
        check("F14b", "确认清理后自动重连且撤卡", reconnected && model.portConflict == nil)
    }

    @MainActor
    private static func bindConflictChecks() async {
        let spy = FeatureTunnelSpy()
        let runtime = ManagedTunnelService(underlying: spy)
        runtime.retryBaseSeconds = 0.03
        runtime.maximumRetrySeconds = 0.05
        runtime.monitorTickSeconds = 0.02
        runtime.remoteBindConflictWindowSeconds = 0.3

        var profile = ServerProfile(name: "192", host: "10.11.154.192", sshPort: 20064, username: "sunyun", remotePort: 7890)
        profile.reconnectEnabled = true
        runtime.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: nil))

        func conflictSnapshot() -> TunnelSnapshot {
            var snap = TunnelSnapshot.idle(profile.id)
            snap.phase = .error
            snap.sshProcessRunning = false
            snap.humanReadableDetail = "远端 127.0.0.1:17890 监听失败：端口可能被占用或服务器禁止转发。"
            return snap
        }
        // 重连结局 = 立即再报冲突（真实协调器在 -R 绑定失败时同样直接退出为 error，不会先报 connected）
        spy.connectOutcome = conflictSnapshot()
        spy.onEvent?(.snapshot(conflictSnapshot()))
        let retried = await waitSmokeUntil { spy.connects.count >= 2 }
        check("F10", "端口冲突（旧 sshd 未释放）窗口内自动重试", retried)

        try? await Task.sleep(nanoseconds: 400_000_000)
        let before = spy.connects.count
        spy.onEvent?(.snapshot(conflictSnapshot()))
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("F11", "窗口过后仍冲突停止自动重试（终态指引）", spy.connects.count == before)
        runtime.terminateAllSessions()

        // F15 本地 Relay 端口冲突：同一限时重试窗口
        let relaySpy = FeatureTunnelSpy()
        let relayRuntime = ManagedTunnelService(underlying: relaySpy)
        relayRuntime.retryBaseSeconds = 0.03
        relayRuntime.maximumRetrySeconds = 0.05
        relayRuntime.monitorTickSeconds = 0.02
        relayRuntime.remoteBindConflictWindowSeconds = 60
        var relayProfile = ServerProfile(name: "relay", host: "10.0.0.7", sshPort: 22, username: "u", remotePort: 7890)
        relayProfile.reconnectEnabled = true
        relayRuntime.connect(configuration: TunnelConfiguration(profile: relayProfile, localEndpoint: nil))
        _ = await waitSmokeUntil { relaySpy.connects.count == 1 }
        var relayError = TunnelSnapshot.idle(relayProfile.id)
        relayError.phase = .error
        relayError.sshProcessRunning = false
        relayError.humanReadableDetail = "本地 Relay 无法启动（端口可能被占用）：地址已被使用"
        relaySpy.onEvent?(.snapshot(relayError))
        let relayRetried = await waitSmokeUntil { relaySpy.connects.count == 2 }
        check("F15", "本地 Relay 端口冲突限时自动重连", relayRetried)
        relayRuntime.terminateAllSessions()
    }

    @MainActor
    private static func networkRestorationChecks() async {
        let spy = FeatureTunnelSpy()
        let runtime = ManagedTunnelService(underlying: spy)
        runtime.retryBaseSeconds = 0.05
        runtime.maximumRetrySeconds = 0.1
        runtime.monitorTickSeconds = 0.05
        runtime.resolveEndpoint = nil

        var reconnect = ServerProfile(name: "r", host: "10.0.0.1", sshPort: 22, username: "u", remotePort: 7890)
        reconnect.reconnectEnabled = true
        let cfg = TunnelConfiguration(profile: reconnect, localEndpoint: nil)
        runtime.connect(configuration: cfg)
        _ = await waitSmokeUntil { spy.connects.count == 1 && spy.isActive(profileID: reconnect.id) }

        // 活跃 + 允许自动重连 → 系统断开 + 立即重建
        runtime.handleNetworkRestoration()
        let reconnected = await waitSmokeUntil { spy.connects.count == 2 }
        check("F06a", "网络恢复：活跃会话回收并立即重建（绕过 ServerAlive 等待）",
              reconnected && spy.systemReasons.contains("网络已恢复"))

        // 未开自动重连：网络恢复不惊动（保持用户语义）
        var manual = ServerProfile(name: "m", host: "10.0.0.2", sshPort: 22, username: "u", remotePort: 7891)
        manual.reconnectEnabled = false
        let manualSpy = FeatureTunnelSpy()
        let manualRuntime = ManagedTunnelService(underlying: manualSpy)
        manualRuntime.connect(configuration: TunnelConfiguration(profile: manual, localEndpoint: nil))
        _ = await waitSmokeUntil { manualSpy.connects.count == 1 }
        manualRuntime.handleNetworkRestoration()
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("F06b", "未开自动重连的会话不被网络恢复触碰",
              manualSpy.connects.count == 1 && manualSpy.systemReasons.isEmpty)
        runtime.terminateAllSessions()
        manualRuntime.terminateAllSessions()
    }

    @MainActor
    private static func upgradeChecks() async {
        final class ScriptedDetector: ProxyDetectorService {
            var onStateChange: (@MainActor (ProxyDetectionState) -> Void)?
            func startObservingSystemChanges() -> Bool { true }
            func detect() {}
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyBridgeSmokeUp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = FeatureTunnelSpy()
        let detector = ScriptedDetector()
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: dir),
            settingsStore: AppSettingsStore(directoryURL: dir),
            tunnel: spy, proxyDetector: detector,
            logStore: LogStore(), secrets: InMemoryPasswordStore()
        )
        var profile = ServerProfile(name: "自动机", host: "10.0.0.3", sshPort: 22, username: "u", remotePort: 7890)
        profile.connectionMode = .automatic
        profile.reconnectEnabled = false
        model.saveDraftProfile(profile)
        profile = model.profiles[0]

        // 活跃动态会话（自动模式回退产物）：先真实 connect 建立 active，再声明动态模式
        spy.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: nil))
        var snap = TunnelSnapshot.idle(profile.id)
        snap.phase = .connected
        snap.sshProcessRunning = true
        snap.remoteProbeVerified = true
        snap.effectiveMode = .reverseDynamic
        spy.onEvent?(.snapshot(snap))

        func push(port: Int) {
            var state = ProxyDetectionState()
            state.candidates = [ProxyCandidate(
                endpoint: LocalProxyEndpoint(host: "127.0.0.1", port: port, protocol: .http, origin: .systemHTTP, verifiedAt: Date()),
                capability: .verified
            )]
            detector.onStateChange?(state)
        }
        push(port: 7898) // 第一次：记录，不升级
        try? await Task.sleep(nanoseconds: 150_000_000)
        check("F07a", "仅一次验证不升级（需连续两次防横跳）", spy.connects.count == 1 && spy.systemReasons.isEmpty)
        push(port: 7898) // 第二次：同一端点 → 升级重连
        let upgraded = await waitSmokeUntil { spy.connects.count == 2 }
        check("F07b", "连续两次验证同一端点 → 断开重建切回静态",
              upgraded && spy.systemReasons.contains { $0.contains("静态转发") })
    }
}
