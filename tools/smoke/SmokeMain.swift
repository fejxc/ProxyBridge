// 冒烟测试（CLI，无 Xcode 依赖）：复用 App 生产源码，真实执行核心逻辑断言。
// 用途：在没有完整 Xcode（无法跑 XCTest）的开发机上提供可执行的验证证据。
// 运行：scripts/smoke_test.sh —— 编译 App 源码（不含 @main 入口）+ 本文件并执行。

import Foundation

@main
struct SmokeMain {
    static var passed = 0
    static var failed = 0

    @MainActor
    static func main() async {
        print("== ProxyBridge 阶段 A 冒烟测试（生产代码直连断言）==")

        validationChecks()
        persistenceChecks()
        redactionChecks()
        presentationChecks()
        templateChecks()
        resolverChecks()
        await mockTunnelChecks()
        await viewModelChecks()

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

    // MARK: S01–S07 校验

    static func validationChecks() {
        func profile(
            name: String = "实验室服务器", host: String = "10.11.154.192",
            sshPort: Int = 20064, username: String = "sunyun", remotePort: Int = 7890
        ) -> ServerProfile {
            ServerProfile(name: name, host: host, sshPort: sshPort, username: username, remotePort: remotePort)
        }

        check("S01", "合法主机/基线通过", ServerProfileRule.validate(profile()).isValid)
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
        let doc = ProfilesDocument(schemaVersion: 1, profiles: [p], currentProfileId: p.id)

        do {
            try repo.save(doc)
            let reloaded = try ProfileRepository(directoryURL: dir).load()
            check("S08", "profile JSON round-trip 全字段一致", reloaded.profiles == doc.profiles && reloaded.currentProfileId == p.id)
        } catch {
            check("S08", "profile JSON round-trip 全字段一致（异常：\(error)）", false)
        }

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
    }

    // MARK: S20 复制模板

    static func templateChecks() {
        let http = RemoteCommandTemplate.exportCommands(remotePort: 7890, protocol: .http)
        check("S20a", "HTTP 模板含 http_proxy/https_proxy", http.contains("export http_proxy=http://127.0.0.1:7890") && http.contains("export https_proxy=http://127.0.0.1:7890"))
        let socks = RemoteCommandTemplate.exportCommands(remotePort: 7891, protocol: .socks5)
        check("S20b", "SOCKS 模板用 socks5h", socks.contains("export ALL_PROXY=socks5h://127.0.0.1:7891"))
        check("S20c", "未验证时附提醒", RemoteCommandTemplate.clipboardText(remotePort: 7890, protocol: .http, remoteVerified: nil).contains("尚未验证"))
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
        if case .none = EndpointResolver.resolve(profile: autoProfile, detection: state) {
            check("S25c", "未验证候选不被采用", true)
        } else {
            check("S25c", "未验证候选不被采用", false)
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
        check("S24", "无本地端点 → degraded + localProxyVerified=false", degraded && b4.all.last?.localProxyVerified == false)
    }

    static func waitSmokeUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
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
        }

        let spy = SpyTunnel()
        let detector = MockProxyDetector()
        detector.simulatedLatency = 0.02
        let model = AppViewModel(
            profileStore: ProfileRepository(directoryURL: dir),
            settingsStore: AppSettingsStore(directoryURL: dir),
            tunnel: spy,
            proxyDetector: detector,
            logStore: LogStore()
        )
        check("S26a", "空启动 → 未配置状态", model.profiles.isEmpty && model.overallPresentation.title == "未配置")

        // 注入已验证候选后保存 profile 并连接
        detector.onStateChange?( {
            var s = ProxyDetectionState()
            s.candidates = [ProxyCandidate(
                endpoint: LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP),
                capability: .verified)]
            return s
        }() )
        var profile = ServerProfile(name: "冒烟机", host: "10.11.154.192", sshPort: 20064, username: "sunyun", remotePort: 7890)
        model.saveDraftProfile(profile)
        model.connect()
        check("S26b", "连接经校验并把已验证端点传给服务",
              spy.box.connects.count == 1 && spy.box.connects.first?.localEndpoint?.port == 7897)

        // 无效配置拦截
        profile.host = "bad host"
        model.upsertProfile(profile)
        model.connect()
        check("S26c", "非法主机阻止连接并置 error", spy.box.connects.count == 1 && model.currentSnapshot.phase == .error)

        // 活跃连接时改参数 → degraded + 重连提示（经服务事件真实路径注入快照）
        spy.onEvent?(.snapshot(TunnelSnapshot(
            profileId: profile.id, phase: .connected, localProxyVerified: true,
            sshProcessRunning: true, remoteProbeVerified: true, lastRemoteProbeAt: Date(),
            humanReadableDetail: "ok"
        )))
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
    }
}
