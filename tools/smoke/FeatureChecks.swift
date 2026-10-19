import Foundation

// P0/P1/P2 功能冒烟检查（本地 CLI 可执行；与 XCTest 互补，覆盖生产装配链路）

extension SmokeMain {

    /// 自包含隧道替身：记录系统断开/重连语义（网络恢复与模式升级用）。
    final class FeatureTunnelSpy: TunnelService {
        var onEvent: (@MainActor (TunnelEvent) -> Void)?
        private let lock = NSLock()
        private var connectLog: [TunnelConfiguration] = []
        private var systemDisconnects: [String] = []
        private var activeIDs: Set<UUID> = []
        func connect(configuration: TunnelConfiguration) {
            lock.lock(); connectLog.append(configuration); activeIDs.insert(configuration.profile.id); lock.unlock()
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
