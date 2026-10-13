import Foundation

extension SmokeMain {
    @MainActor
    static func runtimeChecks() async {
        let profile = ServerProfile(name: "runtime", host: "test.invalid", sshPort: 22, username: "test", remotePort: 7890)
        check("N07", "Codex HTTP compatibility defaults to port 7890 while SOCKS5 stays distinct",
              profile.httpAdapterEnabled && profile.remoteHTTPPort == 7_890
              && profile.remoteSocksPort == 17_890)
        let endpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP)
        let config = TunnelConfiguration(profile: profile, localEndpoint: endpoint)
        let adapterToken = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let adapterPrepare = RemoteHTTPAdapterCommands.prepare(httpPort: 7890, socksPort: 17_890, token: adapterToken)
        let adapterCleanup = RemoteHTTPAdapterCommands.cleanup(token: adapterToken)
        check("P01", "Privoxy 仅写用户会话配置并绑定 HTTP 与 SOCKS 回环端口",
              adapterPrepare.contains("listen-address 127.0.0.1:7890")
              && adapterPrepare.contains("forward-socks5 / 127.0.0.1:17890 .")
              && adapterPrepare.contains("root=\"$HOME/.cache/proxybridge\"")
              && adapterPrepare.contains("privoxy-\(adapterToken)")
              && adapterPrepare.contains("ss -ltn") && adapterPrepare.contains("netstat -lnt")
              && !adapterPrepare.contains("sudo") && !adapterPrepare.contains("apt install"))
        check("P02", "Privoxy 清理只匹配会话 PID 与配置路径，不使用 pkill 或 SIGKILL",
              adapterCleanup.contains("process_id=\"$1\"") && adapterCleanup.contains("ps -ww -p")
              && adapterCleanup.contains("kill \"$pid\"")
              && adapterCleanup.contains("$dir/config")
              && !adapterCleanup.contains("pkill") && !adapterCleanup.contains("kill -9"))
        func shellParses(_ script: String) -> Bool {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyBridge-(UUID()).sh")
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
        check("P03", "Privoxy 准备、启动和清理远端脚本通过本机 POSIX shell 语法检查",
              shellParses(adapterPrepare)
              && shellParses(RemoteHTTPAdapterCommands.launch(token: adapterToken))
              && shellParses(adapterCleanup))
        func snapshot(_ phase: TunnelPhase, detail: String = "") -> TunnelSnapshot {
            var value = TunnelSnapshot.idle(profile.id)
            value.phase = phase; value.humanReadableDetail = detail
            value.sshProcessRunning = phase == .connected || phase == .degraded
            value.localProxyVerified = value.sshProcessRunning ? true : nil
            value.remoteProbeVerified = value.sshProcessRunning ? true : nil
            return value
        }
        func make() -> (ManagedTunnelService, RuntimeTunnelSpy) {
            let spy = RuntimeTunnelSpy()
            let runtime = ManagedTunnelService(underlying: spy)
            runtime.retryBaseSeconds = 0.03
            runtime.maximumRetrySeconds = 0.1
            runtime.monitorTickSeconds = 0.01
            runtime.localIntervalOverride = 0.03
            runtime.remoteIntervalOverride = 0.08
            runtime.wakeDelaySeconds = 0.03
            return (runtime, spy)
        }
        check("D01", "指数退避有上限", ManagedTunnelService.retryDelay(attempt: 0) == 1
              && ManagedTunnelService.retryDelay(attempt: 3) == 8 && ManagedTunnelService.retryDelay(attempt: 100) == 60)
        check("D02", "认证与转发配置错误不自动重试",
              !ManagedTunnelService.shouldRetry(snapshot(.authRequired))
              && !ManagedTunnelService.shouldRetry(snapshot(.error, detail: "远程监听端口建立失败")))
        let (runtime, spy) = make()
        runtime.connect(configuration: config)
        runtime.connect(configuration: config)
        check("D03", "运行时仍防止双连击", spy.connections.count == 1)
        spy.emit(snapshot(.error, detail: "网络不可达"))
        let retried = await waitSmokeUntil { spy.connections.count == 2 }
        check("D04", "网络断线自动建立新连接", retried)
        spy.emit(snapshot(.error, detail: "网络不可达"))
        runtime.disconnect(profileID: profile.id)
        let stoppedCount = spy.connections.count
        try? await Task.sleep(nanoseconds: 150_000_000)
        check("D05", "用户断开取消退避并保持终态", spy.connections.count == stoppedCount && !runtime.isActive(profileID: profile.id))
        runtime.terminateAllSessions()

        let (auth, authSpy) = make()
        auth.connect(configuration: config)
        authSpy.emit(snapshot(.authRequired, detail: "服务器主机密钥未通过校验"))
        auth.prepareForSleep(); auth.resumeAfterWake()
        try? await Task.sleep(nanoseconds: 100_000_000)
        check("D06", "认证终态在唤醒后也不重试", authSpy.connections.count == 1)
        auth.terminateAllSessions()

        let (periodic, periodicSpy) = make()
        periodic.connect(configuration: config)
        periodicSpy.emit(snapshot(.connected))
        let checked = await waitSmokeUntil { periodicSpy.localChecks > 0 && periodicSpy.remoteChecks > 0 }
        check("D07", "本地与远端检查按各自周期调度", checked)
        periodic.disconnect(profileID: profile.id)
        let checkCount = periodicSpy.localChecks + periodicSpy.remoteChecks
        try? await Task.sleep(nanoseconds: 100_000_000)
        check("D08", "断开后停止周期探测", periodicSpy.localChecks + periodicSpy.remoteChecks == checkCount)
        periodic.terminateAllSessions()

        let (wake, wakeSpy) = make()
        wake.connect(configuration: config); wakeSpy.emit(snapshot(.connected))
        wake.prepareForSleep(); wake.resumeAfterWake()
        let woke = await waitSmokeUntil { wakeSpy.connections.count == 2 }
        check("D09", "睡眠清理进程，唤醒恢复允许的连接", woke && wakeSpy.stops == 1)
        wakeSpy.emit(snapshot(.connected)); wake.prepareForSleep()
        wake.disconnect(profileID: profile.id); wake.resumeAfterWake()
        try? await Task.sleep(nanoseconds: 100_000_000)
        check("D10", "休眠期间手动断开不在唤醒后恢复", wakeSpy.connections.count == 2)
        wake.terminateAllSessions()

        let (disabled, disabledSpy) = make()
        disabled.connect(configuration: config)
        disabledSpy.emit(snapshot(.error, detail: "网络不可达"))
        disabled.updateReconnectPreference(profileID: profile.id, enabled: false, rememberPassword: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        check("D11", "关闭自动重连立即取消待重试任务", disabledSpy.connections.count == 1 && !disabled.isActive(profileID: profile.id))
        disabled.terminateAllSessions()

        let (off, offSpy) = make()
        var noRecovery = config; noRecovery.profile.reconnectEnabled = false
        off.connect(configuration: noRecovery); offSpy.emit(snapshot(.connected))
        off.prepareForSleep(); off.resumeAfterWake()
        try? await Task.sleep(nanoseconds: 100_000_000)
        check("D24", "未启用恢复的连接不在唤醒后重建", offSpy.connections.count == 1)
        off.terminateAllSessions()
        let (cancel, cancelSpy) = make()
        cancel.connect(configuration: config)
        cancel.onEvent = { event in
            if case .snapshot(let state) = event, state.phase == .reconnecting { cancel.disconnect(profileID: state.profileId) }
        }
        cancelSpy.emit(snapshot(.error, detail: "网络不可达"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        check("D25", "重连事件中同步断开也无残留恢复任务", cancelSpy.connections.count == 1 && !cancel.isActive(profileID: profile.id))
        cancel.onEvent = nil
        cancel.terminateAllSessions()

        let remote = SmokeRemoteProber(outcome: .verified(statusCode: 200))
        let base = SSHTunnelCoordinator(processFactory: SmokeSSHFactory(), localProber: SmokeLocalProber(outcome: .verified(statusCode: 200)),
            remoteProber: remote, secrets: InMemoryPasswordStore())
        base.graceSeconds = 0.01; base.remoteProbeCooldown = 0
        var baseLatest: TunnelSnapshot?
        base.onEvent = { if case .snapshot(let value) = $0 { baseLatest = value } }
        base.connect(configuration: config)
        _ = await waitSmokeUntil { baseLatest?.phase == .connected }
        let beforeLocal = remote.callCount
        base.runLocalHealthCheck(profileID: profile.id)
        _ = await waitSmokeUntil { baseLatest?.humanReadableDetail.contains("本地健康检查完成") == true }
        check("D26", "生产本地轻量检查不启动远端 SSH", remote.callCount == beforeLocal)
        remote.outcome = .unknown(reason: "timeout")
        base.runHealthCheck(profileID: profile.id)
        _ = await waitSmokeUntil { baseLatest?.phase == .degraded }
        check("D27", "周期远端无法验证时清除旧绿色结论", baseLatest?.phase == .degraded && baseLatest?.remoteProbeVerified == nil)
        remote.outcome = .authRequired(detail: "服务器主机密钥未通过校验")
        base.runHealthCheck(profileID: profile.id)
        _ = await waitSmokeUntil { baseLatest?.phase == .authRequired }
        check("D28", "周期认证失败终止隧道并停止继续探测", baseLatest?.phase == .authRequired && baseLatest?.sshProcessRunning == false && !base.isActive(profileID: profile.id))
        base.terminateAllSessions()

        var dynamicProfile = profile
        dynamicProfile.connectionMode = .reverseDynamic
        dynamicProfile.httpAdapterEnabled = false // isolate the SOCKS-only lifecycle
        let dynamicFactory = SmokeSSHFactory()
        let dynamicLocal = SmokeLocalProber(outcome: .connectionRefused)
        let dynamicRemote = SmokeRemoteProber(outcome: .verified(statusCode: 401))
        let dynamic = SSHTunnelCoordinator(
            processFactory: dynamicFactory,
            localProber: dynamicLocal,
            remoteProber: dynamicRemote,
            secrets: InMemoryPasswordStore()
        )
        dynamic.graceSeconds = 0.01
        dynamic.remoteProbeCooldown = 0
        var dynamicLatest: TunnelSnapshot?
        dynamic.onEvent = { if case .snapshot(let value) = $0 { dynamicLatest = value } }
        dynamic.connect(configuration: TunnelConfiguration(profile: dynamicProfile, localEndpoint: nil))
        let dynamicConnected = await waitSmokeUntil { dynamicLatest?.phase == .connected }
        let dynamicForward = dynamicFactory.lastArguments.firstIndex(of: "-R")
        check("N01", "動態 SOCKS5 在無本地端點時跳過本地探測並驗證 SOCKS 远端请求",
              dynamicConnected && dynamicLocal.callCount == 0
              && dynamicRemote.lastRemotePort == 17_890 && dynamicRemote.lastProtocol == .socks5
              && dynamicLatest?.effectiveMode == .reverseDynamic
              && dynamicLatest?.networkReachability == true
              && dynamicForward.map { dynamicFactory.lastArguments[$0 + 1] == "127.0.0.1:17890" } == true)
        dynamic.disconnect(profileID: dynamicProfile.id)
        dynamic.terminateAllSessions()

        var automaticProfile = profile
        automaticProfile.connectionMode = .automatic
        automaticProfile.httpAdapterEnabled = false // isolate the SOCKS-only fallback
        let automaticFactory = SmokeSSHFactory()
        let automaticLocal = SmokeLocalProber(outcome: .connectionRefused)
        let automaticRemote = SmokeRemoteProber(outcome: .verified(statusCode: 401))
        let automatic = SSHTunnelCoordinator(
            processFactory: automaticFactory,
            localProber: automaticLocal,
            remoteProber: automaticRemote,
            secrets: InMemoryPasswordStore()
        )
        automatic.graceSeconds = 0.01
        automatic.remoteProbeCooldown = 0
        var automaticLatest: TunnelSnapshot?
        automatic.onEvent = { if case .snapshot(let value) = $0 { automaticLatest = value } }
        automatic.connect(configuration: TunnelConfiguration(profile: automaticProfile, localEndpoint: nil))
        let automaticConnected = await waitSmokeUntil { automaticLatest?.phase == .connected }
        check("N02", "自动模式未发现本地端点后回退到动态 SOCKS5",
              automaticConnected && automaticLocal.callCount == 0
              && automaticLatest?.effectiveMode == .reverseDynamic
              && automaticLatest?.selectionReason?.contains("未发现") == true
              && automaticRemote.lastProtocol == .socks5)
        automatic.disconnect(profileID: automaticProfile.id)
        automatic.terminateAllSessions()

        let failedCandidateFactory = SmokeSSHFactory()
        let failedCandidateLocal = SmokeLocalProber(outcome: .connectionRefused)
        let failedCandidateRemote = SmokeRemoteProber(outcome: .verified(statusCode: 401))
        let failedCandidate = SSHTunnelCoordinator(
            processFactory: failedCandidateFactory,
            localProber: failedCandidateLocal,
            remoteProber: failedCandidateRemote,
            secrets: InMemoryPasswordStore()
        )
        failedCandidate.graceSeconds = 0.01
        failedCandidate.remoteProbeCooldown = 0
        var failedCandidateLatest: TunnelSnapshot?
        failedCandidate.onEvent = { if case .snapshot(let value) = $0 { failedCandidateLatest = value } }
        failedCandidate.connect(configuration: TunnelConfiguration(profile: automaticProfile, localEndpoint: endpoint))
        let autoFallback = await waitSmokeUntil { failedCandidateLatest?.phase == .connected }
        check("N03a", "自动模式本地协议实测失败后切换动态 SOCKS5",
              autoFallback && failedCandidateLocal.callCount == 1
              && failedCandidateRemote.lastProtocol == .socks5
              && failedCandidateLatest?.effectiveMode == .reverseDynamic
              && failedCandidateLatest?.selectionReason?.contains("未通过实测") == true)
        failedCandidate.disconnect(profileID: automaticProfile.id)
        failedCandidate.terminateAllSessions()

        var staticProfile = profile
        staticProfile.connectionMode = .staticForward
        let staticLocal = SmokeLocalProber(outcome: .verified(statusCode: 200))
        let staticFactory = SmokeSSHFactory()
        var staticLatest: TunnelSnapshot?
        let staticCoordinator = SSHTunnelCoordinator(
            processFactory: staticFactory,
            localProber: staticLocal,
            remoteProber: SmokeRemoteProber(outcome: .verified(statusCode: 200)),
            secrets: InMemoryPasswordStore()
        )
        staticCoordinator.graceSeconds = 0.01
        staticCoordinator.onEvent = { if case .snapshot(let value) = $0 { staticLatest = value } }
        staticCoordinator.connect(configuration: TunnelConfiguration(profile: staticProfile, localEndpoint: nil))
        let staticRejected = await waitSmokeUntil { staticLatest?.phase == .degraded }
        check("N03", "显式静态模式缺少本地端点时不切换动态模式",
              staticRejected && staticFactory.handles.isEmpty && staticLocal.callCount == 0)
        staticCoordinator.terminateAllSessions()

        var bPlusProfile = profile
        bPlusProfile.connectionMode = .reverseDynamic
        let bPlusRemote = SmokeRemoteProber(outcome: .verified(statusCode: 401))
        let bPlusManager = SmokeHTTPAdapterManager(result: .started(RemoteHTTPAdapterSession(
            token: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", handle: SmokeSSHHandle()
        )))
        let bPlus = SSHTunnelCoordinator(
            processFactory: SmokeSSHFactory(),
            localProber: SmokeLocalProber(outcome: .connectionRefused),
            remoteProber: bPlusRemote,
            secrets: InMemoryPasswordStore(),
            httpAdapterManager: bPlusManager
        )
        bPlus.graceSeconds = 0.01
        bPlus.remoteProbeCooldown = 0
        var bPlusLatest: TunnelSnapshot?
        bPlus.onEvent = { if case .snapshot(let value) = $0 { bPlusLatest = value } }
        bPlus.connect(configuration: TunnelConfiguration(profile: bPlusProfile, localEndpoint: nil))
        let bPlusConnected = await waitSmokeUntil { bPlusLatest?.phase == .connected }
        check("N04", "B+ 在 SOCKS5 验活后启动，并单独验证 HTTP CONNECT",
              bPlusConnected && bPlusRemote.history.map { $0.1 } == [.socks5, .http]
              && bPlusManager.starts == 1 && bPlusLatest?.httpAdapterStatus == .verified
              && bPlusLatest?.remoteProbeVerified == true)
        bPlus.disconnect(profileID: bPlusProfile.id)
        _ = await waitSmokeUntil { bPlusManager.cleanups == 1 }
        bPlus.terminateAllSessions()

        let noPrivoxyManager = SmokeHTTPAdapterManager(result: .notInstalled)
        let noPrivoxyRemote = SmokeRemoteProber(outcome: .verified(statusCode: 401))
        let noPrivoxy = SSHTunnelCoordinator(
            processFactory: SmokeSSHFactory(),
            localProber: SmokeLocalProber(outcome: .connectionRefused),
            remoteProber: noPrivoxyRemote,
            secrets: InMemoryPasswordStore(),
            httpAdapterManager: noPrivoxyManager
        )
        noPrivoxy.graceSeconds = 0.01
        noPrivoxy.remoteProbeCooldown = 0
        var noPrivoxyLatest: TunnelSnapshot?
        noPrivoxy.onEvent = { if case .snapshot(let value) = $0 { noPrivoxyLatest = value } }
        noPrivoxy.connect(configuration: TunnelConfiguration(profile: bPlusProfile, localEndpoint: nil))
        let socksFallback = await waitSmokeUntil { noPrivoxyLatest?.phase == .degraded }
        check("N05", "Privoxy 不存在时保留已验证 SOCKS5 并报告 HTTP 不可用",
              socksFallback && noPrivoxyLatest?.remoteProbeVerified == true
              && noPrivoxyLatest?.httpAdapterStatus == .notInstalled
              && noPrivoxyRemote.callCount == 1)
        noPrivoxy.disconnect(profileID: bPlusProfile.id)
        noPrivoxy.terminateAllSessions()

        var mixedProfile = profile
        mixedProfile.connectionMode = .staticForward
        let mixedEndpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 8890, protocol: .mixed, origin: .manual)
        let mixedLocal = SmokeLocalProber(outcome: .verified(statusCode: 200))
        let mixedRemote = SmokeRemoteProber(outcome: .verified(statusCode: 200))
        let mixedCoordinator = SSHTunnelCoordinator(
            processFactory: SmokeSSHFactory(), localProber: mixedLocal, remoteProber: mixedRemote,
            secrets: InMemoryPasswordStore()
        )
        mixedCoordinator.graceSeconds = 0.01
        mixedCoordinator.remoteProbeCooldown = 0
        var mixedLatest: TunnelSnapshot?
        mixedCoordinator.onEvent = { if case .snapshot(let value) = $0 { mixedLatest = value } }
        mixedCoordinator.connect(configuration: TunnelConfiguration(profile: mixedProfile, localEndpoint: mixedEndpoint))
        let mixedConnected = await waitSmokeUntil { mixedLatest?.phase == .connected }
        check("N06", "静态 Mixed 上游分别完成 HTTP 与 SOCKS5 探测",
              mixedConnected && mixedLocal.callCount == 2 && mixedRemote.lastProtocol == .mixed)
        mixedCoordinator.disconnect(profileID: mixedProfile.id)
        mixedCoordinator.terminateAllSessions()

        var policy = ConnectionNotificationPolicy()
        let now = Date()
        check("D12", "通知按服务器去重并冷却", policy.shouldSend(profileID: profile.id, now: now)
              && !policy.shouldSend(profileID: profile.id, now: now.addingTimeInterval(10))
              && policy.shouldSend(profileID: profile.id, now: now.addingTimeInterval(301)))
        check("D13", "通知不携带连接地址或身份", ConnectionNotificationPolicy.message(for: .authRequired)?.contains("test.invalid") == false
              && ConnectionNotificationPolicy.message(for: .connected) == nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyBridgeRuntime-\(UUID())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ProfileRepository(directoryURL: directory)
        var startup = profile; startup.connectAtLaunch = true
        var ordinary = profile; ordinary.id = UUID(); ordinary.connectAtLaunch = false
        try? repository.save(ProfilesDocument(schemaVersion: 1, profiles: [startup, ordinary], currentProfileId: ordinary.id))
        let startupSpy = RuntimeTunnelSpy()
        let detector = MockProxyDetector(); detector.simulatedLatency = 0.01
        let system = RuntimeSystemSpy()
        let model = AppViewModel(profileStore: repository, settingsStore: AppSettingsStore(directoryURL: directory),
            tunnel: startupSpy, proxyDetector: detector, logStore: LogStore(), secrets: InMemoryPasswordStore(), systemServices: system)
        _ = await waitSmokeUntil { !startupSpy.connections.isEmpty }
        check("D14", "启动只连接明确勾选的服务器", startupSpy.connections.map { $0.profile.id } == [startup.id])
        check("D15", "启动不擅自请求通知授权", system.requests == 0)
        model.requestNotificationPermission()
        _ = await waitSmokeUntil { system.requests == 1 }
        check("D16", "通知授权由用户操作触发", system.requests == 1)
        model.setLaunchAtLogin(true)
        _ = await waitSmokeUntil { !model.changingLoginState }
        check("D17", "登录项等待批准时如实显示", model.loginLaunchEnabled && model.loginStatusDescription.contains("等待系统授权"))
        model.setLaunchAtLogin(false)
        _ = await waitSmokeUntil { !model.changingLoginState }
        system.loginShouldFail = true
        model.setLaunchAtLogin(true)
        _ = await waitSmokeUntil { !model.changingLoginState }
        check("D18", "登录项注册失败不保存为已启用", !model.loginLaunchEnabled && !model.settings.launchAtLoginRequested
              && model.loginStatusDescription.contains("失败"))
        startupSpy.onEvent?(.passwordPromptRequested(profileID: startup.id))
        startupSpy.onEvent?(.passwordPromptRequested(profileID: ordinary.id))
        model.submitPassword(UUID().uuidString, remember: false)
        check("D19", "多个服务器密码请求依次呈现，不覆盖前一请求", model.pendingPasswordProfileId == ordinary.id)
        model.cancelPasswordPrompt()
        check("D20", "取消密码后清理输入卡", model.pendingPasswordProfileId == nil)
        var failure = TunnelSnapshot.idle(startup.id)
        failure.phase = .error; failure.humanReadableDetail = "网络不可达"
        startupSpy.emit(failure)
        let notified = await waitSmokeUntil { system.notifications.count == 1 }
        failure.humanReadableDetail = "网络不可达：再次失败"
        startupSpy.emit(failure)
        try? await Task.sleep(nanoseconds: 30_000_000)
        check("D21", "实际通知链路合并重复异常", notified && system.notifications.count == 1)
        startupSpy.disconnect(profileID: startup.id)
        model.degradedNotificationDelaySeconds = 0.04
        var degraded = TunnelSnapshot.idle(startup.id)
        degraded.phase = .degraded
        startupSpy.emit(degraded)
        startupSpy.disconnect(profileID: startup.id)
        try? await Task.sleep(nanoseconds: 100_000_000)
        check("D22", "用户断开取消待发的持续降级通知", system.notifications.count == 1)
        model.updateSettings { $0.showNotifications = false }
        startupSpy.emit(failure)
        try? await Task.sleep(nanoseconds: 30_000_000)
        check("D23", "关闭通知后不发送并清理原提醒", system.notifications.isEmpty)
        model.shutdown()
    }
}
