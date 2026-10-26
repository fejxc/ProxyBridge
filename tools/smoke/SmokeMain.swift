// 冒烟测试（CLI，无 Xcode 依赖）：复用 App 生产源码，真实执行核心逻辑断言。
// 用途：在没有完整 Xcode（无法跑 XCTest）的开发机上提供可执行的验证证据。
// 运行：scripts/smoke_test.sh —— 编译 App 源码（不含 @main 入口）+ 本文件并执行。

import Foundation
import Network

@main
struct SmokeMain {
    static var passed = 0
    static var failed = 0

    @MainActor
    static func main() async {
        // 冒烟断言全部按中文文案：固定语言，隔离 CI runner 的系统语言（en-US）
        L10n.apply(.chinese)
        print("== ProxyBridge 阶段 A 冒烟测试（生产代码直连断言）==")

        validationChecks()
        persistenceChecks()
        redactionChecks()
        presentationChecks()
        templateChecks()
        resolverChecks()
        await mockTunnelChecks()
        await viewModelChecks()
        await retargetWiringChecks()
        logStoreChecks()
        diagnosticsChecks()
        await liveProxyChecks()
        sshChecks()
        await askpassChecks()
        rawErrorLineChecks()
        await probeRegressionChecks()
        await runtimeChecks()
        await relayLifecycleChecks()
        await relayRetargetChecks()
        await tunnelCoordinatorChecks()
        await featureChecks()
        loopbackGuardChecks()

        print("----------------------------------------")
        print("通过 \(passed) 项，失败 \(failed) 项")
        if failed > 0 {
            print("RESULT: FAIL")
            exit(1)
        }
        print("RESULT: PASS")
    }

    // MARK: 断言辅助

    static func check(_ id: String, _ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            passed += 1
            print("PASS  \(id)  \(name)")
        } else {
            failed += 1
            print("FAIL  \(id)  \(name)")
        }
    }

    // 密码认证改走 SSH_ASKPASS（OpenSSH ≥ 8.4 force 模式）：真实执行 helper
    // 脚本验证交付语义，并核对凭据文件的权限与生命周期。
    static func askpassChecks() async {
        let secret = "s3cret-\(UUID().uuidString)"
        guard let credential = SSHAskpassCredential(password: secret) else {
            check("ASK01", "创建凭据装置", false)
            return
        }
        let env = credential.environmentAdditions
        check("ASK01", "环境注入三件套（force + helper 路径 + 凭据路径）",
              env["SSH_ASKPASS_REQUIRE"] == "force"
                  && env["SSH_ASKPASS"]?.hasSuffix("askpass-helper.sh") == true
                  && env[SSHAskpassCredential.credentialFileEnvKey]?.hasSuffix("credential") == true)
        let helperPath = env["SSH_ASKPASS"] ?? ""
        let credentialPath = env[SSHAskpassCredential.credentialFileEnvKey] ?? ""
        check("ASK02", "helper 可执行且凭据文件 0600",
              FileManager.default.isExecutableFile(atPath: helperPath)
                  && (try? FileManager.default.attributesOfItem(atPath: credentialPath)[.posixPermissions] as? Int) == 0o600)
        check("ASK03", "凭据目录 0700 且不含密码内容本身",
              (try? FileManager.default.attributesOfItem(
                  atPath: (credentialPath as NSString).deletingLastPathComponent
              )[.posixPermissions] as? Int) == 0o700
              && !helperPath.contains(secret) && !credentialPath.contains(secret))

        // 真实执行 helper：语义即 OpenSSH 调用 askpass（stdout 取密码，行尾换行被剥离）
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [helperPath]
        task.environment = env
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        do {
            try task.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let delivered = String(decoding: data, as: UTF8.self)
            // 凭据文件即密码原文（无行尾换行）；OpenSSH 对 askpass 输出按
            // 「剥离一个行尾换行（若存在）」处理，两种形态语义一致
            check("ASK04", "helper 真实交付密码（stdout）", delivered == secret)
            check("ASK05", "交付路径不含机密（argv/env 只有路径）",
                  task.arguments?.contains(secret) != true)
        } catch {
            check("ASK04", "helper 真实交付密码（stdout）", false)
            check("ASK05", "交付路径不含机密（argv/env 只有路径）", false)
        }

        credential.destroy()
        check("ASK06", "destroy 幂等且删除整个凭据目录",
              !FileManager.default.fileExists(atPath: credentialPath)
                  && !FileManager.default.fileExists(atPath: (credentialPath as NSString).deletingLastPathComponent))
        credential.destroy() // 第二次调用不得抛错/崩溃
        check("ASK07", "destroy 幂等（二次调用安全）", true)

        // 残留清扫不得误删活跃（新建）凭据目录
        guard let active = SSHAskpassCredential(password: "active") else {
            check("ASK08", "清扫保留活跃凭据", false)
            return
        }
        SSHAskpassCredential.sweepStaleDirectories()
        let activePath = active.environmentAdditions[SSHAskpassCredential.credentialFileEnvKey] ?? ""
        check("ASK08", "清扫保留活跃凭据", FileManager.default.fileExists(atPath: activePath))
        active.destroy()
    }

    // 错误透传：分类器须挑出 sshd 的「原话」而不是噪声/首行
    static func rawErrorLineChecks() {
        let stderr = "Warning: Permanently added the host.\n"
            + "debug1: Connecting to server port 22\n"
            + "channel 2: open failed: administratively prohibited\n"
            + "Warning: remote port forwarding failed for listen port 7890\n"
        let line = SSHErrorClassifier.mostInformativeLine(stderr: stderr)
        check("RAW1", "优先取含故障关键词的最后一行", line?.contains("forwarding failed") == true)
        check("RAW2", "剔除 known_hosts 噪声，保留转发失败原话",
              line?.contains("Permanently added") != true)
        check("RAW3", "空输入安全", SSHErrorClassifier.mostInformativeLine(stderr: "") == nil)
        let long = String(repeating: "x", count: 300) + " connection refused"
        let capped = SSHErrorClassifier.mostInformativeLine(stderr: long)
        check("RAW4", "超长行截断至 160 字符", capped?.count == 160 && capped?.hasSuffix("x") == true)
    }

    @MainActor
    static func probeRegressionChecks() async {
        check("R06", "拒绝选项样式的代理主机，允许合法连字符主机",
              !CurlProxyProbe.isValidProbeHost("--evil-flag") && CurlProxyProbe.isValidProbeHost("proxy-host.example"))
        let script = RemoteProbeCommand.script(remotePort: 1, protocol: .http,
                                               urlString: CurlProxyProbe.verificationURL)
        func run(_ environment: [String: String]) async -> (Int32, String, String) {
            let handle = FoundationSSHProcessHandle(arguments: ["-c", script],
                environment: environment, executableURL: URL(fileURLWithPath: "/bin/sh"))
            do { try handle.start() } catch { return (-1, "", "start failed") }
            let deadline = Date().addingTimeInterval(10)
            while handle.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if handle.isRunning { handle.forceTerminate(); return (-1, "", "timeout") }
            return (handle.exitCode ?? -1, handle.stdoutTail, handle.stderrTail)
        }
        let missing = await run(["PATH": "/nonexistent"])
        check("R01", "远端脚本仅在 curl 不存在时报告缺失",
              SSHRemoteProbe.parse(exitCode: missing.0, stdout: missing.1, stderr: missing.2) == .remoteCurlMissing)
        let refused = await run(SSHProcessLauncher.sshEnvironment())
        let failed = SSHRemoteProbe.parse(exitCode: refused.0, stdout: refused.1, stderr: refused.2)
        if case .connectionFailure = failed {
            check("R02", "实际 curl 连接失败保留失败原因，不误报缺 curl", refused.0 != 0 && !refused.1.contains(RemoteProbeCommand.noCurlMarker))
        } else { check("R02", "实际 curl 连接失败保留失败原因，不误报缺 curl", false) }
        check("R03", "失败退出码不得显示已验证",
              !SSHRemoteProbe.parse(exitCode: 7, stdout: "200", stderr: "").isVerified)

        let local = SmokeLocalProber(outcome: .verified(statusCode: 200))
        let remote = SmokeRemoteProber(outcome: .verified(statusCode: 200))
        let coordinator = SSHTunnelCoordinator(processFactory: SmokeSSHFactory(),
            localProber: local, remoteProber: remote, secrets: InMemoryPasswordStore())
        coordinator.graceSeconds = 0.1
        coordinator.remoteProbeCooldown = 0
        let profile = ServerProfile(name: "regression", host: "test.invalid", sshPort: 22, username: "test",
                                    remotePort: 7890, preferredProtocol: .socks5)
        let endpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP)
        var latest: TunnelSnapshot?
        coordinator.onEvent = { if case .snapshot(let snapshot) = $0 { latest = snapshot } }
        coordinator.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: endpoint))
        _ = await waitSmokeUntil { latest?.phase == .connected }
        check("R04", "远端探测使用隧道实际协议", remote.lastProtocol == .http)
        local.outcome = .connectionRefused
        coordinator.runHealthCheck(profileID: profile.id)
        _ = await waitSmokeUntil { latest?.phase == .degraded }
        check("R05", "健康检查重新验证自动端点，失败时降级",
              local.callCount == 2 && latest?.localProxyVerified == false && latest?.phase == .degraded)
        coordinator.terminateAllSessions()
    }

    // MARK: S01–S07 校验

    static func validationChecks() {
        func profile(
            name: String = "实验室服务器", host: String = "10.11.154.192",
            sshPort: Int = 20064, username: String = "sunyun", remotePort: Int = 17891
        ) -> ServerProfile {
            ServerProfile(name: name, host: host, sshPort: sshPort, username: username, remotePort: remotePort)
        }

        check("S01", "合法主机/基线通过", ServerProfileRule.validate(profile()).isValid)
        check("S01b", "HTTP 入口与静态转发端口重叠时拒绝保存",
              !ServerProfileRule.validate(profile(remotePort: 7890)).isValid)
        for bad in ["bad host", "host;rm -rf /", "$(whoami).x.com", "`id`.x.com", "a|b", "hÖst", "", "::1", "example..com"] {
            check("S02", "拒绝非法主机「\(bad)」", !ServerProfileRule.validate(profile(host: bad)).isValid)
        }
        check("S03a", "拒绝非法用户名 user;id", !ServerProfileRule.validate(profile(username: "user;id")).isValid)
        check("S03b", "拒绝空用户名", !ServerProfileRule.validate(profile(username: "")).isValid)
        check("S03c", "拒绝符号开头用户名 -root", !ServerProfileRule.validate(profile(username: "-root")).isValid)
        check("S03d", "接受正常用户名", ServerProfileRule.validate(profile(username: "dev_01")).isValid)
        check("S04a", "SSH 端口 0 拒绝", !ServerProfileRule.validate(profile(sshPort: 0)).isValid)
        check("S04b", "SSH 端口 65536 拒绝", !ServerProfileRule.validate(profile(sshPort: 65_536)).isValid)
        check("S04c", "远程端口 0 拒绝", !ServerProfileRule.validate(profile(remotePort: 0)).isValid)
        check("S04d", "远程端口 65536 拒绝", !ServerProfileRule.validate(profile(remotePort: 65_536)).isValid)
        check("S04e", "端口 1/65535 接受", ServerProfileRule.validate(profile(sshPort: 1, remotePort: 65_535)).isValid)
        check("S04f", "远程端口 <1024 产生警告但可保存", {
            let v = ServerProfileRule.validate(profile(remotePort: 80))
            return v.isValid && !v.warnings.isEmpty
        }())
        check("S05a", "空名称拒绝", !ServerProfileRule.validate(profile(name: "")).isValid)
        check("S05b", "41 字名称拒绝", !ServerProfileRule.validate(profile(name: String(repeating: "字", count: 41))).isValid)
        var idProfile = profile()
        idProfile.authMode = .identityFile
        idProfile.identityFilePath = nil
        check("S06a", "identityFile 无路径拒绝", !ServerProfileRule.validate(idProfile).isValid)
        idProfile.identityFilePath = "/nonexistent/.ssh/key"
        let idv = ServerProfileRule.validate(idProfile)
        check("S06b", "密钥文件不存在仅警告", idv.isValid && !idv.warnings.isEmpty)
        check("S07a", "非回环手动端点拒绝", !LocalProxyEndpointRule.isValid(host: "192.168.1.1", port: 7897))
        check("S07b", "回环手动端点接受", LocalProxyEndpointRule.isValid(host: "127.0.0.1", port: 7897))
        check("S07c", "::1 回环接受", LocalProxyEndpointRule.isValid(host: "::1", port: 1080))
    }

    // MARK: S08–S12 持久化

    static func persistenceChecks() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyBridgeSmoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = ProfileRepository(directoryURL: dir)
        var p = ServerProfile(
            name: "实验室 GPU 服务器", host: "10.11.154.192", sshPort: 20064,
            username: "sunyun", authMode: .identityFile,
            identityFilePath: "~/.ssh/id_ed25519", remotePort: 7890,
            proxySelectionMode: .manual,
            manualEndpoint: LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .socks5, origin: .manual),
            preferredProtocol: .socks5, reconnectEnabled: false, connectAtLaunch: true
        )
        p.id = UUID()
        var doc = ProfilesDocument(schemaVersion: 1, profiles: [p], currentProfileId: p.id)
        doc.defaultProfileId = p.id

        do {
            try repo.save(doc)
            let reloaded = try ProfileRepository(directoryURL: dir).load()
            check("S08", "profile JSON round-trip 全字段一致", reloaded.profiles == doc.profiles && reloaded.currentProfileId == p.id && reloaded.defaultProfileId == p.id)
        } catch {
            check("S08", "profile JSON round-trip 全字段一致（异常：\(error)）", false)
        }

        // 旧格式文件无 defaultProfileId 字段 → 解码为 nil（向后兼容）
        try? "{\"schemaVersion\":1,\"currentProfileId\":null,\"profiles\":[]}".data(using: .utf8)!
            .write(to: dir.appendingPathComponent("profiles.json"))
        let legacyDoc = try? ProfileRepository(directoryURL: dir).load()
        check("S08b", "旧格式 profiles.json 解码 defaultProfileId 为 nil", legacyDoc != nil && legacyDoc?.defaultProfileId == nil)

        // 损坏恢复
        let fileURL = dir.appendingPathComponent("profiles.json")
        try? "{\"profiles\": [broken".data(using: .utf8)!.write(to: fileURL)
        var threw = false
        do { _ = try repo.load() } catch { threw = true }
        check("S09a", "损坏文件抛 .corrupted", threw)
        let quarantined = (try? repo.quarantineCorruptFile()) != nil
        let emptyAfter = (try? repo.load())?.profiles.isEmpty ?? false
        check("S09b", "隔离后加载为空", quarantined && emptyAfter)

        // 重复 id 去重
        let id = UUID()
        let dupJSON = """
        {"schemaVersion":1,"currentProfileId":"\(id.uuidString)","profiles":[
        {"id":"\(id.uuidString)","name":"A","host":"a.example.com","sshPort":22,"username":"u","authMode":"agent","remotePort":7890,"proxySelectionMode":"automatic","preferredProtocol":"http","reconnectEnabled":true,"connectAtLaunch":false},
        {"id":"\(id.uuidString)","name":"B","host":"b.example.com","sshPort":22,"username":"u","authMode":"agent","remotePort":7891,"proxySelectionMode":"automatic","preferredProtocol":"http","reconnectEnabled":true,"connectAtLaunch":false}]}
        """
        try? dupJSON.data(using: .utf8)!.write(to: fileURL)
        let dedup = (try? repo.load())?.profiles.count == 1
        check("S10", "重复 profile id 去重", dedup)

        // 悬空 currentProfileId
        let real = UUID()
        let ghostJSON = """
        {"schemaVersion":1,"currentProfileId":"\(UUID().uuidString)","profiles":[
        {"id":"\(real.uuidString)","name":"A","host":"a.example.com","sshPort":22,"username":"u","authMode":"agent","remotePort":7890,"proxySelectionMode":"automatic","preferredProtocol":"http","reconnectEnabled":true,"connectAtLaunch":false}]}
        """
        try? ghostJSON.data(using: .utf8)!.write(to: fileURL)
        check("S11", "悬空 currentProfileId 回退首个", (try? repo.load())?.currentProfileId == real)

        // 设置
        let settingsStore = AppSettingsStore(directoryURL: dir)
        var s = AppSettings.defaults()
        s.remoteCheckIntervalSeconds = 60
        s.redactLogsOnCopy = false
        try? settingsStore.save(s)
        let s2 = settingsStore.load()
        var s3 = s2
        s3.remoteCheckIntervalSeconds = 999
        check("S12", "设置 round-trip + 非法间隔回退默认", s2.redactLogsOnCopy == false && s3.sanitized.remoteCheckIntervalSeconds == 60)
    }

    // MARK: S13–S16 脱敏

    static func redactionChecks() {
        check("S13a", "剥离 ANSI CSI", LogRedaction.sanitize("\u{1B}[31mRED\u{1B}[0m text") == "RED text")
        check("S13b", "剥离 OSC(BEL)", LogRedaction.sanitize("a\u{1B}]0;t\u{07}b") == "ab")
        check("S13c", "剥离 OSC(ST)", LogRedaction.sanitize("x\u{1B}]2;t\u{1B}\\y") == "xy")
        check("S13d", "删除 CR/BEL 保留 \\n\\t", LogRedaction.sanitize("a\rb\nc\td\u{7}e") == "ab\nc\td" + "e")
        check("S13e", "不留 ESC 字符", !LogRedaction.sanitize("k\u{1B}Eep").contains("\u{1B}"))
        let long = String(repeating: "a", count: LogRedaction.maxMessageLength + 500)
        check("S14", "超长截断", LogRedaction.sanitize(long).hasSuffix("…(截断)"))
        check("S15a", "密钥路径遮挡", LogRedaction.redact("key /Users/alice/.ssh/id_ed25519", options: .keyPaths).contains("[密钥路径]"))
        check("S15b", "用户@主机遮挡", LogRedaction.redact("to sunyun@10.11.154.192", options: .userHost).contains("[用户@主机]"))
        check("S15c", "IP 遮挡", LogRedaction.redact("host 192.168.1.100 down", options: .ipAddresses).contains("[IP]"))
        check("S15d", "Bearer 凭据遮挡", LogRedaction.redact("Bearer abcdef1234567890", options: .tokens) == "Bearer [凭据]")
        check("S15e", "公钥内容遮挡", LogRedaction.redact("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbcdefg", options: .tokens).contains("[公钥内容]"))
        let stored = LogRedaction.sanitizeForStorage("ssh -i ~/.ssh/k sunyun@10.11.154.192 Bearer abcdef1234567890 \u{1B}[31me\u{1B}[0m")
        check("S16", "入库 sanitize+脱敏组合（IP 保留供排障）",
              !stored.contains(".ssh/") && !stored.contains("abcdef") && !stored.contains("\u{1B}") && stored.contains("10.11.154.192"))
    }

    // MARK: S17–S19 状态展示

    static func presentationChecks() {
        let pid = UUID()
        func snap(_ phase: TunnelPhase, local: Bool? = nil, ssh: Bool = false, remote: Bool? = nil) -> TunnelSnapshot {
            TunnelSnapshot(profileId: pid, phase: phase, localProxyVerified: local,
                           sshProcessRunning: ssh, remoteProbeVerified: remote,
                           lastRemoteProbeAt: nil, humanReadableDetail: "d")
        }
        check("S17a", "nil 绝不算端到端验证", !snap(.connected, ssh: true, remote: nil).isEndToEndVerified)
        check("S17b", "connected+远端未验证 → 橙「部分可用」", {
            let p = TunnelStatusPresentation.overall(for: snap(.connected, local: true, ssh: true, remote: nil))
            return p.tone == .orange && p.title == "部分可用"
        }())
        check("S17c", "connected+远端已验证 → 绿", TunnelStatusPresentation.overall(for: snap(.connected, local: true, ssh: true, remote: true)).tone == .green)
        check("S18a", "idle → 灰 未连接", TunnelStatusPresentation.overall(for: snap(.idle)).tone == .gray)
        check("S18b", "checking/connecting → 蓝", TunnelStatusPresentation.overall(for: snap(.checking)).tone == .blue && TunnelStatusPresentation.overall(for: snap(.connecting)).tone == .blue)
        check("S18c", "本地代理失败 → 橙 代理异常", {
            let p = TunnelStatusPresentation.overall(for: snap(.degraded, local: false, ssh: true))
            return p.tone == .orange && p.title == "代理异常"
        }())
        check("S18d", "authRequired/error → 红", TunnelStatusPresentation.overall(for: snap(.authRequired)).tone == .red && TunnelStatusPresentation.overall(for: snap(.error)).tone == .red)
        check("S19a", "健康三元组：已验证连接全 ok", {
            let t = TunnelStatusPresentation.healthTriad(for: snap(.connected, local: true, ssh: true, remote: true))
            return t.local == .ok && t.ssh == .ok && t.remote == .ok
        }())
        check("S19b", "健康三元组：idle 本地=未知/SSH=失败", {
            let t = TunnelStatusPresentation.healthTriad(for: snap(.idle))
            return t.local == .unknown && t.ssh == .failed
        }())
        check("S19c", "健康三元组：进程死亡 SSH=失败", {
            let t = TunnelStatusPresentation.healthTriad(for: snap(.connected, local: true, ssh: false, remote: true))
            return t.ssh == .failed
        }())
        check("S19d", "健康摘要：全过 → 绿「3 项检查通过」+ 刚刚验证", {
            let now = Date()
            let s = TunnelStatusPresentation.healthSummary(
                checks: [(title: "a", display: .ok), (title: "b", display: .ok), (title: "c", display: .ok)],
                lastVerifiedAt: now.addingTimeInterval(-10),
                now: now
            )
            return s.title == "3 项检查通过" && s.detail == "刚刚验证" && s.tone == .green && !s.shouldExpandDetails
        }())
        check("S19e", "健康摘要：unknown 如实计数，绝不并入通过", {
            let s = TunnelStatusPresentation.healthSummary(
                checks: [(title: "a", display: .ok), (title: "b", display: .ok), (title: "c", display: .unknown)]
            )
            return s.title == "2/3 项已验证" && s.tone == .orange && !s.shouldExpandDetails
        }())
        check("S19f", "健康摘要：失败 → 红、置位展开、点名失败行", {
            let s = TunnelStatusPresentation.healthSummary(
                checks: [
                    (title: "本地代理", display: .ok),
                    (title: "SSH 隧道", display: .failed),
                    (title: "远端代理", display: .failed),
                    (title: "HTTP 入口", display: .unknown)
                ]
            )
            return s.title == "2 项检查未通过" && s.tone == .red && s.shouldExpandDetails
                && s.failedTitles == ["SSH 隧道", "远端代理"]
                && s.detail == "SSH 隧道、远端代理；另 1 项未验证"
        }())
        check("S19g", "健康摘要：空列表 → 灰占位", TunnelStatusPresentation.healthSummary(checks: []).tone == .gray)
    }

    // MARK: LD 日志修复建议

    static func diagnosticsChecks() {
        let auth = LogDiagnostics.hint(for: "SSH 失败: Permission denied (publickey)")
        check("LD01", "认证失败 → 建议核对凭据并重新输入", auth?.title == "SSH 认证失败" && (auth?.suggestion.contains("重新输入") ?? false))
        let port = LogDiagnostics.hint(for: "bind 127.0.0.1:17891: Address already in use")
        check("LD02", "端口占用 → 建议换远程监听端口", port?.title == "远端端口冲突")
        check("LD03", "普通信息日志不硬造建议", LogDiagnostics.hint(for: "ProxyBridge 启动") == nil)
        check("LD04", "多行/超长消息判定为默认折叠",
              LogDiagnostics.needsCollapse("a\nb") && LogDiagnostics.needsCollapse(String(repeating: "x", count: 121)) && !LogDiagnostics.needsCollapse("短"))
    }

    // MARK: S20 复制模板

    static func templateChecks() {
        let http = RemoteCommandTemplate.exportCommands(remotePort: 7890, protocol: .http)
        check("S20a", "HTTP 模板含 http_proxy/https_proxy", (http ?? "").contains("export http_proxy=http://127.0.0.1:7890") && (http ?? "").contains("export https_proxy=http://127.0.0.1:7890"))
        check("S20a2", "非法端口返回 nil 不崩溃", RemoteCommandTemplate.exportCommands(remotePort: 65_536, protocol: .http) == nil)
        let socks = RemoteCommandTemplate.exportCommands(remotePort: 7891, protocol: .socks5)
        check("S20b", "SOCKS 模板用 socks5h", (socks ?? "").contains("export ALL_PROXY=socks5h://127.0.0.1:7891"))
        check("S20c", "未验证时附提醒", (RemoteCommandTemplate.clipboardText(remotePort: 7890, protocol: .http, remoteVerified: nil) ?? "").contains("尚未验证"))
    }

    // MARK: S25 端点解析

    static func resolverChecks() {
        var state = ProxyDetectionState()
        state.candidates = [
            ProxyCandidate(endpoint: LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP), capability: .verified),
        ]
        let manual = LocalProxyEndpoint(host: "127.0.0.1", port: 1080, protocol: .socks5, origin: .manual)
        let manualProfile = ServerProfile(name: "t", host: "a.example.com", sshPort: 22, username: "u", remotePort: 7890, proxySelectionMode: .manual, manualEndpoint: manual)
        check("S25a", "手动端点优先于自动检测", EndpointResolver.resolve(profile: manualProfile, detection: state) == .manual(manual))
        let autoProfile = ServerProfile(name: "t", host: "a.example.com", sshPort: 22, username: "u", remotePort: 7890)
        if case .auto(let ep) = EndpointResolver.resolve(profile: autoProfile, detection: state) {
            check("S25b", "自动模式取已验证端点", ep.port == 7897)
        } else {
            check("S25b", "自动模式取已验证端点", false)
        }
        state.candidates = state.candidates.map { ProxyCandidate(endpoint: $0.endpoint, capability: .untested) }
        if case .auto(let fallback) = EndpointResolver.resolve(profile: autoProfile, detection: state) {
            check("S25c", "未验证回环候选作为回退（连接时实时探测定生死）", fallback.port == 7897)
        } else {
            check("S25c", "未验证回环候选作为回退（连接时实时探测定生死）", false)
        }
    }

    // MARK: S21–S24 Mock 隧道

    @MainActor
    static func mockTunnelChecks() async {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [TunnelSnapshot] = []
            func append(_ s: TunnelSnapshot) { lock.lock(); defer { lock.unlock() }; items.append(s) }
            var all: [TunnelSnapshot] { lock.lock(); defer { lock.unlock() }; return items }
        }

        var profile = ServerProfile(name: "t", host: "10.11.154.192", sshPort: 20064, username: "sunyun", remotePort: 7890)
        profile.id = UUID()
        let endpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP)

        func makeService() -> (MockTunnelService, Box) {
            let service = MockTunnelService()
            service.stepDelay = 0.03
            let box = Box()
            service.onEvent = { event in
                if case .snapshot(let s) = event { box.append(s) }
            }
            return (service, box)
        }

        // S21 正常时序
        let (s1, b1) = makeService()
        s1.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: endpoint))
        let ok1 = await waitSmokeUntil { b1.all.last?.phase == .connected }
        let phases = b1.all.map(\.phase)
        check("S21", "时序 checking→connecting→connected 且终态字段正确", ok1
              && phases.firstIndex(of: .checking) != nil
              && (phases.firstIndex(of: .checking)! < phases.firstIndex(of: .connecting) ?? -1)
              && (phases.firstIndex(of: .connecting)! < phases.firstIndex(of: .connected) ?? -1)
              && b1.all.last?.localProxyVerified == true
              && b1.all.last?.remoteProbeVerified == true)

        // S22 双连击
        let (s2, b2) = makeService()
        let cfg2 = TunnelConfiguration(profile: profile, localEndpoint: endpoint)
        s2.connect(configuration: cfg2)
        s2.connect(configuration: cfg2)
        _ = await waitSmokeUntil { b2.all.last?.phase == .connected }
        check("S22", "同一 profile 重复连接只产生一个序列（U14）",
              b2.all.filter { $0.phase == .checking }.count == 1 && b2.all.filter { $0.phase == .connected }.count == 1)

        // S23 用户断开 → idle 后零事件
        let (s3, b3) = makeService()
        s3.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: endpoint))
        _ = await waitSmokeUntil { b3.all.contains { $0.phase == .checking } }
        s3.disconnect(profileID: profile.id)
        let stopped = await waitSmokeUntil { b3.all.last?.phase == .idle }
        let countAtStop = b3.all.count
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("S23", "用户断开后到达 idle 且不再有任何事件（U13）",
              stopped && b3.all.count == countAtStop && b3.all.last?.phase == .idle)

        // S24 无端点 → degraded
        let (s4, b4) = makeService()
        s4.connect(configuration: TunnelConfiguration(profile: profile, localEndpoint: nil))
        let degraded = await waitSmokeUntil { b4.all.last?.phase == .degraded }
        check("S24", "无本地端点 → degraded + localProxyVerified=nil（未发现）", degraded && b4.all.last?.localProxyVerified == nil)
    }

    static func waitSmokeUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: S37 代理变化动态感知接线（ViewModel 层：端点变化 → 无缝切换；本地失败 → 主动重扫）

    @MainActor
    static func retargetWiringChecks() async {
        final class RetargetSpyTunnel: TunnelService {
            var onEvent: (@MainActor (TunnelEvent) -> Void)?
            private let lock = NSLock()
            private var calls: [(UUID, LocalProxyEndpoint)] = []
            var activeID: UUID?
            func connect(configuration: TunnelConfiguration) {}
            func disconnect(profileID: UUID) {}
            func runHealthCheck(profileID: UUID) {}
            func isActive(profileID: UUID) -> Bool { profileID == activeID }
            func terminateAllSessions() {}
            func submitPassword(profileID: UUID, password: String, remember: Bool) {}
            func cancelPasswordPrompt(profileID: UUID) {}
            func retargetLocalEndpoint(profileID: UUID, endpoint: LocalProxyEndpoint) {
                lock.lock()
                calls.append((profileID, endpoint))
                lock.unlock()
            }
            var retargets: [(UUID, LocalProxyEndpoint)] {
                lock.lock(); defer { lock.unlock() }
                return calls
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyBridgeSmokeRT-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let spy = RetargetSpyTunnel()
        let detector = MockProxyDetector()
        detector.simulatedLatency = 0.02
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: dir),
            settingsStore: AppSettingsStore(directoryURL: dir),
            tunnel: spy,
            proxyDetector: detector,
            logStore: LogStore(),
            secrets: InMemoryPasswordStore()
        )
        model.saveDraftProfile(ServerProfile(name: "动态跟随", host: "10.11.154.192", sshPort: 22, username: "sunyun", remotePort: 17891))
        let profile = model.profiles[0]
        spy.activeID = profile.id

        // 活跃静态会话：当前使用 7897 端点
        var snap = TunnelSnapshot.idle(profile.id)
        snap.phase = .connected
        snap.sshProcessRunning = true
        snap.localProxyVerified = true
        snap.remoteProbeVerified = true
        snap.effectiveMode = .staticForward
        snap.activeLocalEndpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP)
        spy.onEvent?(.snapshot(snap))

        func push(port: Int) {
            var state = ProxyDetectionState()
            state.candidates = [ProxyCandidate(
                endpoint: LocalProxyEndpoint(host: "127.0.0.1", port: port, protocol: .http, origin: .systemHTTP, verifiedAt: Date()),
                capability: .verified
            )]
            detector.onStateChange?(state)
        }
        push(port: 7898)
        let wired = await waitSmokeUntil { spy.retargets.count == 1 }
        check("S37a", "端点变化 → 活跃静态隧道下发无缝切换", wired && spy.retargets.first?.1.port == 7898)

        push(port: 7898) // 重复扫描（verifiedAt 变化，端点 id 不变）
        try? await Task.sleep(nanoseconds: 250_000_000)
        check("S37b", "端点未变的重复扫描不重复切换", spy.retargets.count == 1)

        // 本地验证失败（degraded + localProxyVerified=false + SSH 存活）→ 主动重扫，冷却窗口内不重复
        let detectCallsBefore = detector.detectCalls
        var failed = snap
        failed.phase = .degraded
        failed.localProxyVerified = false
        failed.humanReadableDetail = "本地健康检查完成：代理未通过验证"
        spy.onEvent?(.snapshot(failed))
        spy.onEvent?(.snapshot(failed))
        check("S37c", "本地验证失败触发主动重扫（冷却窗口内仅一次）", detector.detectCalls == detectCallsBefore + 1)
    }

    // MARK: S26 ViewModel（持久化联动 / 校验拦截 / 需重连降级）

    @MainActor
    static func viewModelChecks() async {
        final class VMBox: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [TunnelConfiguration] = []
            private var disconnects: [UUID] = []
            func recordConnect(_ c: TunnelConfiguration) { lock.lock(); defer { lock.unlock() }; items.append(c) }
            func recordDisconnect(_ id: UUID) { lock.lock(); defer { lock.unlock() }; disconnects.append(id) }
            var connects: [TunnelConfiguration] { lock.lock(); defer { lock.unlock() }; return items }
            var disconnectList: [UUID] { lock.lock(); defer { lock.unlock() }; return disconnects }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyBridgeSmokeVM-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        final class SpyTunnel: TunnelService {
            var onEvent: (@MainActor (TunnelEvent) -> Void)?
            let box = VMBox()
            func connect(configuration: TunnelConfiguration) { box.recordConnect(configuration) }
            func disconnect(profileID: UUID) { box.recordDisconnect(profileID) }
            func runHealthCheck(profileID: UUID) {}
            func isActive(profileID: UUID) -> Bool { false }
            func terminateAllSessions() {}
            func submitPassword(profileID: UUID, password: String, remember: Bool) {}
            func cancelPasswordPrompt(profileID: UUID) {}
        }

        let spy = SpyTunnel()
        let detector = MockProxyDetector()
        detector.simulatedLatency = 0.02
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: dir),
            settingsStore: AppSettingsStore(directoryURL: dir),
            tunnel: spy,
            proxyDetector: detector,
            logStore: LogStore(),
            secrets: InMemoryPasswordStore()
        )
        L10n.apply(.chinese) // model 初始化会按系统语言（CI=en）切换；断言固定中文
        check("S26a", "空启动 → 未配置状态", model.profiles.isEmpty && model.overallPresentation.title == "未配置")

        // 注入已验证候选后保存 profile 并连接
        detector.onStateChange?( {
            var s = ProxyDetectionState()
            s.candidates = [ProxyCandidate(
                endpoint: LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP),
                capability: .verified)]
            return s
        }() )
        var profile = ServerProfile(name: "冒烟机", host: "10.11.154.192", sshPort: 20064, username: "sunyun", remotePort: 17891, preferredProtocol: .socks5)
        model.saveDraftProfile(profile)
        model.connect()
        check("S26b", "连接经校验并把已验证端点传给服务",
              spy.box.connects.count == 1 && spy.box.connects.first?.localEndpoint?.port == 7897)

        check("S26k", "复制命令采用实际 HTTP 候选而非 SOCKS5 偏好",
              model.remoteCommandText()?.contains("http://127.0.0.1:17891") == true)

        // 无效配置拦截（U06 两个半边）
        profile.host = "bad host"
        let invalidSaved = model.saveDraftProfile(profile)
        check("S26i", "非法主机拒绝保存（不落盘不进列表）", !invalidSaved && model.profiles.count == 1)
        model.upsertProfile(profile) // 模拟绕过 UI 的注入路径
        model.connect()
        check("S26c", "注入的非法主机仍阻止连接并置 error", spy.box.connects.count == 1 && model.currentSnapshot.phase == .error)
        profile.host = "10.11.154.192"
        model.upsertProfile(profile) // 恢复合法配置继续后续检查

        // 活跃连接时改参数 → degraded + 重连提示（经服务事件真实路径注入快照）
        spy.onEvent?(.snapshot(TunnelSnapshot(
            profileId: profile.id, phase: .connected, localProxyVerified: true,
            sshProcessRunning: true, remoteProbeVerified: true, lastRemoteProbeAt: Date(),
            humanReadableDetail: "ok"
        )))
        let priorLogs = model.logStore.entries.count
        spy.onEvent?(.snapshot(TunnelSnapshot(
            profileId: profile.id, phase: .connected, localProxyVerified: true,
            sshProcessRunning: true, remoteProbeVerified: true, lastRemoteProbeAt: Date(),
            humanReadableDetail: "手动检查完成：远端验证通过（HTTP 200）"
        )))
        check("S26l", "状态不变时仍记录真实健康检查结果",
              model.logStore.entries.count == priorLogs + 1
              && model.logStore.entries.last?.message.contains("HTTP 200") == true)
        profile.remotePort = 7891
        model.upsertProfile(profile)
        check("S26d", "活跃连接改参数 → degraded + 需重连", model.snapshots[profile.id]?.phase == .degraded)

        // 手动端点
        let errs = model.applyManualEndpoint(host: "0.0.0.0", port: 7897, protocol: .http)
        let okApply = model.applyManualEndpoint(host: "127.0.0.1", port: 1080, protocol: .socks5)
        check("S26e", "手动端点校验（拒绝非回环）", !errs.isEmpty && okApply.isEmpty && model.currentProfile?.manualEndpoint?.port == 1080)

        // 落盘重读
        let reloaded = (try? ProfileRepository(directoryURL: dir).load())
        check("S26f", "VM 修改真实落盘", reloaded?.profiles.count == 1 && reloaded?.profiles.first?.proxySelectionMode == .manual)

        // 断开路由
        model.disconnect()
        check("S26g", "断开请求路由到服务", spy.box.disconnectList == [profile.id])

        // 复制命令
        let cmd = model.remoteCommandText()
        check("S26h", "复制命令按协议生成且未验证提醒", cmd?.contains("尚未验证") == true)

        // 端口冲突提示（F02）
        var samePort = profile
        samePort.id = UUID()
        samePort.name = "同端口第二台"
        let conflict = model.remotePortConflictDescription(for: samePort)
        check("S26j", "同主机同远程端口冲突提示", conflict?.contains("远程端口") == true && conflict?.contains("互相") == true)
        var otherHost = profile
        otherHost.id = UUID()
        otherHost.host = "other.example.com"
        check("S26k", "不同主机同端口不误报", model.remotePortConflictDescription(for: otherHost) == nil)
    }

    // MARK: S27 LogStore / AppSettingsStore

    @MainActor
    static func logStoreChecks() {
        let store = LogStore()
        for i in 0..<(LogStore.capacity + 2) {
            store.append(raw: "e-\(i)", level: .info)
        }
        check("S27a", "日志环形容量收敛并保留最新",
              store.entries.count == LogStore.capacity && store.entries.last?.message == "e-\(LogStore.capacity + 1)")

        store.append(raw: "event \u{1B}[31mx\u{1B}[0m ~/.ssh/id_rsa", level: .info)
        let last = store.entries.last?.message ?? ""
        check("S27b", "正常日志 + ANSI 剥离 + 密钥遮挡",
              last.hasPrefix("event x ") && !last.contains("\u{1B}") && !last.contains(".ssh/"))

        store.append(raw: "ip 10.11.154.192 sunyun@10.11.154.192", level: .success)
        let redacted = store.exportText(redacted: true)
        let raw = store.exportText(redacted: false)
        check("S27c", "导出格式与脱敏开关",
              redacted.contains("[成功]") && !redacted.contains("10.11.154.192") && raw.contains("10.11.154.192"))
    }

    // MARK: S28 真实 curl 探测（本机回环，无外网依赖）+ S29 真实系统读取

    @MainActor
    static func liveProxyChecks() async {
        let probe = CurlProxyProbe(connectTimeoutSeconds: 2, maxTimeSeconds: 4)

        // S28a：连接一个必然拒绝的回环端口 → connectionRefused，绝不 verified
        let refused = await probe.probe(host: "127.0.0.1", port: 1, protocol: .http)
        check("S28a", "真实 curl：拒绝连接 → connectionRefused", refused == .connectionRefused)

        // S28b：本机起一个「普通 HTTP 服务器」（对 CONNECT 应答 404）→ 探测不得给出 verified
        guard let server = Self.startFakePlainHTTPServer() else {
            check("S28b", "假 HTTP 服务器启动（Network.framework）", false)
            return
        }
        defer { server.stop() }
        let notProxy = await probe.probe(host: "127.0.0.1", port: Int(server.port), protocol: .http)
        let notGreen: Bool
        switch notProxy {
        case .verified:
            notGreen = false
        case .reachableNotProxy, .authRequired, .connectionRefused, .timeout, .tlsError, .failed:
            notGreen = true
        }
        check("S28b", "真实 curl：非代理端口绝不变绿（实际：\(notProxy)）", notGreen)

        // S29：真实读取本机系统代理（对照 scutil --proxy），打印证据
        let snapshot = SCDynamicStoreProxyProvider().readProxies()
        func describe(_ p: SystemProxySnapshot.ExplicitProxy?) -> String {
            p.map { "\($0.host):\($0.port)" } ?? "未启用"
        }
        print("—— 本机系统代理（scutil --proxy 对照）——")
        print("   HTTP  = \(describe(snapshot.http))")
        print("   HTTPS = \(describe(snapshot.https))")
        print("   SOCKS = \(describe(snapshot.socks))")
        print("   PAC   = \(snapshot.pacEnabled ? (snapshot.pacURL ?? "启用") : "关闭")")
        check("S29a", "真实读取系统代理：启用的端口字段合法",
              [snapshot.http, snapshot.https, snapshot.socks].compactMap { $0 }.allSatisfy {
                  (1...65_535).contains($0.port) && !$0.host.isEmpty
              })
        let built = ProxyCandidateBuilder.build(from: snapshot)
        print("   候选  = " + built.candidates.map { "\($0.endpoint.protocol.rawValue)|\($0.endpoint.displayEndpoint)" }.joined(separator: ", "))
        check("S29b", "候选构建与系统设置一致（HTTP/HTTPS 字段 → HTTP 候选）",
              (snapshot.http != nil || snapshot.https != nil) == built.candidates.contains { $0.endpoint.protocol == .http })

        // S30：对真实系统代理做端到端协议实测（信息性证据：代理未运行时如实呈现非 verified）
        if let systemProxy = snapshot.http {
            let real = await probe.probe(host: systemProxy.host, port: systemProxy.port, protocol: .http)
            switch real {
            case .verified(let code):
                print("   实测  = 经系统代理 \(systemProxy.host):\(systemProxy.port) 访问 api.openai.com/v1/models 成功（HTTP \(code)）")
                check("S30", "端到端实测：本机系统代理真实可用", true)
            default:
                // 代理未运行/无外网时不虚增通过数：如实打印，不计 PASS
                print("   实测  = 系统代理存在但未通过端到端验证（\(real)）——如实呈现（信息项，不计 PASS）")
            }
        } else {
            print("   实测  = 本机未启用 HTTP 系统代理，跳过端到端实测")
        }
    }

    // MARK: S36 回环判定（真实检测链路的关键闸门，曾因实现 bug 静默跳过探测）

    static func loopbackGuardChecks() {
        check("S36a", "isLoopback(127.0.0.1) == true（用户场景）", ProxyCandidateBuilder.isLoopback("127.0.0.1"))
        check("S36b", "isLoopback 覆盖 127/8", ProxyCandidateBuilder.isLoopback("127.8.8.8"))
        check("S36c", "isLoopback 覆盖 ::1 与 localhost", ProxyCandidateBuilder.isLoopback("::1") && ProxyCandidateBuilder.isLoopback("localhost"))
        check("S36d", "非回环不被误判", !ProxyCandidateBuilder.isLoopback("10.0.0.2") && !ProxyCandidateBuilder.isLoopback("::2"))
    }

    // MARK: S31–S33 SSH 命令构建 / 错误分类 / 真实 ssh 进程

    @MainActor
    static func sshChecks() {
        // S31：参数数组逐字断言（U08 严格性）
        let profile = ServerProfile(
            name: "smoke", host: "10.11.154.192", sshPort: 20064,
            username: "sunyun", remotePort: 7890
        )
        let endpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP)
        let args = SSHCommandBuilder.arguments(profile: profile, localEndpoint: endpoint)
        check("S31a", "ssh 参数数组逐字匹配（StrictHostKeyChecking=yes）", args == [
            "-p", "20064", "-N", "-T",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes",
            "-R", "127.0.0.1:7890:127.0.0.1:7897", "sunyun@10.11.154.192",
        ])
        let spaced = SSHCommandBuilder.arguments(
            profile: ServerProfile(
                name: "s", host: "h.example.com", sshPort: 22, username: "u",
                authMode: .identityFile, identityFilePath: "/Users/x/My Keys/k.pem",
                remotePort: 7890
            ),
            localEndpoint: endpoint
        )
        if let i = spaced.firstIndex(of: "-i") {
            check("S31b", "含空格密钥路径逐字保真", spaced[i + 1] == "/Users/x/My Keys/k.pem")
        } else {
            check("S31b", "含空格密钥路径逐字保真", false)
        }

        // S32：分类映射（U09/U10）
        let auth = SSHErrorClassifier.classify(exitCode: 255, stderr: "Permission denied (publickey).")
        let fwd = SSHErrorClassifier.classify(exitCode: 255, stderr: "Warning: remote port forwarding failed for listen port 7890")
        let refused = SSHErrorClassifier.classify(exitCode: 255, stderr: "ssh: connect to host 127.0.0.1 port 1: Connection refused")
        check("S32", "分类：认证→authRequired / 转发失败→error / 拒连→error",
              isAuthRequired(auth) && isError(fwd) && isError(refused))

        // S33：真实 /usr/bin/ssh 启动（对 127.0.0.1:1，预期立即 Connection refused）
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") else {
            print("   S33 信息：本机无 /usr/bin/ssh，跳过真实进程检查（不计 PASS/FAIL）")
            return
        }
        let factory = FoundationSSHProcessFactory()
        let target = ServerProfile(
            name: "local", host: "127.0.0.1", sshPort: 1,
            username: "nobody", remotePort: 7890
        )
        let realArgs = SSHCommandBuilder.arguments(profile: target, localEndpoint: endpoint)
        let handle = factory.make(arguments: realArgs, environment: SSHProcessLauncher.sshEnvironment())
        do {
            try handle.start()
            let deadline = Date().addingTimeInterval(10)
            while handle.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let code = handle.exitCode
            let classification = SSHErrorClassifier.classify(exitCode: code ?? 255, stderr: handle.stderrTail)
            let detail = "exit=\(code.map(String.init) ?? "running") stderr=\(handle.stderrTail.prefix(60))"
            check("S33", "真实 /usr/bin/ssh 启动并按 stderr 分类（拒连→error）[\(detail)]",
                  code != nil && isError(classification))
            // 句柄必须已终结（无泄漏）
            handle.terminate()
        } catch {
            check("S33", "真实 /usr/bin/ssh 启动（异常：\(error)）", false)
        }
    }

    // MARK: S34 生产 SSHTunnelCoordinator 状态机序列（真实协调器代码 + 测试替身进程）

    @MainActor
    static func tunnelCoordinatorChecks() async {
        let profile = ServerProfile(
            name: "协调器", host: "10.11.154.192", sshPort: 20064,
            username: "sunyun", remotePort: 7890
        )
        let endpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP)
        let cfg = TunnelConfiguration(profile: profile, localEndpoint: endpoint)

        // S34a：完整序列到 connected
        let factory = SmokeSSHFactory()
        let coordinator = SSHTunnelCoordinator(
            processFactory: factory,
            localProber: SmokeLocalProber(outcome: .verified(statusCode: 200)),
            remoteProber: SmokeRemoteProber(outcome: .verified(statusCode: 200)),
            secrets: InMemoryPasswordStore()
        )
        coordinator.graceSeconds = 0.1
        var snapshots: [TunnelSnapshot] = []
        coordinator.onEvent = { (event: TunnelEvent) in
            if case .snapshot(let s) = event { snapshots.append(s) }
        }
        coordinator.connect(configuration: cfg)
        let connected = await waitSmokeUntil(timeout: 3) { snapshots.last?.phase == .connected }
        let phases = snapshots.map(\.phase)
        check("S34a", "协调器完整序列 checking→connecting→connected", connected
              && phases.firstIndex(of: .checking) != nil
              && phases.firstIndex(of: .connecting) != nil
              && snapshots.last?.isEndToEndVerified == true)

        // S34b：用户断开 → idle 后零事件（U13 在真实协调器上成立）
        coordinator.disconnect(profileID: profile.id)
        let idle = await waitSmokeUntil(timeout: 3) { snapshots.last?.phase == .idle }
        let count = snapshots.count
        try? await Task.sleep(nanoseconds: 400_000_000)
        check("S34b", "协调器：用户断开 → idle 且零 ghost 事件", idle && snapshots.count == count
              && snapshots.last?.humanReadableDetail.contains("不会自动重连") == true)

        // S34c：认证失败剧本 → authRequired（I01 语义）
        let factory2 = SmokeSSHFactory()
        let badHandle = SmokeSSHHandle()
        badHandle.stderrText = "sunyun@10.11.154.192: Permission denied (publickey)."
        badHandle.autoExitNanoseconds = 50_000_000
        badHandle.autoExitCode = 255
        factory2.enqueue(badHandle)
        let coordinator2 = SSHTunnelCoordinator(
            processFactory: factory2,
            localProber: SmokeLocalProber(outcome: .verified(statusCode: 200)),
            remoteProber: SmokeRemoteProber(outcome: .verified(statusCode: 200)),
            secrets: InMemoryPasswordStore()
        )
        coordinator2.graceSeconds = 1.0
        var snaps2: [TunnelSnapshot] = []
        coordinator2.onEvent = { (event: TunnelEvent) in
            if case .snapshot(let s) = event { snaps2.append(s) }
        }
        coordinator2.connect(configuration: cfg)
        let authRequired = await waitSmokeUntil(timeout: 3) { snaps2.last?.phase == .authRequired }
        check("S34c", "协调器：认证失败剧本 → authRequired（I01/U09）", authRequired
              && snaps2.last?.humanReadableDetail.contains("认证") == true)

        // S34d：远端缺 curl → degraded 且 remoteProbe=nil（U11：绝不假绿）
        let coordinator3 = SSHTunnelCoordinator(
            processFactory: SmokeSSHFactory(),
            localProber: SmokeLocalProber(outcome: .verified(statusCode: 200)),
            remoteProber: SmokeRemoteProber(outcome: .remoteCurlMissing),
            secrets: InMemoryPasswordStore()
        )
        coordinator3.graceSeconds = 0.1
        var snaps3: [TunnelSnapshot] = []
        coordinator3.onEvent = { (event: TunnelEvent) in
            if case .snapshot(let s) = event { snaps3.append(s) }
        }
        coordinator3.connect(configuration: cfg)
        let degraded = await waitSmokeUntil(timeout: 3) { snaps3.last?.phase == .degraded }
        check("S34d", "协调器：远端缺 curl → degraded + 未验证（绝不 connected）", degraded
              && snaps3.last?.remoteProbeVerified == nil
              && snaps3.last?.phase != .connected)
    }

    private static func isAuthRequired(_ c: SSHErrorClassifier.Classification) -> Bool {
        if case .authRequired = c { return true }
        return false
    }

    private static func isError(_ c: SSHErrorClassifier.Classification) -> Bool {
        if case .error = c { return true }
        return false
    }

    /// 本机假「普通 HTTP 服务器」：接受连接、读请求、回 404、断开。
    /// 用于验证 curl 经它的 CONNECT 不会产生 verified（真实网络证据，无外网依赖）。
    static func startFakePlainHTTPServer() -> (port: UInt16, stop: () -> Void)? {
        let queue = DispatchQueue(label: "smoke.fakeserver")
        guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let body = Data("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard case .ready = listener.state, let port = listener.port?.rawValue else {
            listener.cancel()
            return nil
        }
        return (port, { listener.cancel() })
    }
}
