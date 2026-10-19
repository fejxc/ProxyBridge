import Foundation

/// 真实隧道协调器（TunnelService 的生产实现）。
///
/// 每 profile 严格一个 Session：一个 setup Task + 至多一个 ssh 进程。
/// 状态承诺：
/// - `connected` 严格表示「本地代理已验证 + ssh 存活 + 远端端到端 curl 验证成功」；
/// - 远端缺 curl / 探测超时 → degraded（remoteProbe = nil 未验证），绝不冒充成功；
/// - 用户断开为终态（userStopped）：之后零事件、不自动重连（U13）；
/// - 重复 connect 请求被忽略（U14）；
/// - 只终止本 App 拥有的进程句柄，绝不全局 pkill。
@MainActor
final class SSHTunnelCoordinator: TunnelService {
    var onEvent: (@MainActor (TunnelEvent) -> Void)?

    private let processFactory: any SSHProcessFactory
    private let localProber: any ProxyProbeExecuting
    private let remoteProber: any RemoteProbeExecuting
    private let secrets: any PasswordStoring
    private let relayFactory: (any TCPRelayMaking)?
    private let httpAdapterManager: (any RemoteHTTPAdapterManaging)?

    /// 转发建立宽限（秒）：ExitOnForwardFailure=yes 下绑定失败会在认证后立即退出，
    /// 进程存活超过该窗口即认为转发已建立（再由远端探测给出端到端结论）。
    var graceSeconds: Double = 3.0
    /// 远端探测最小冷却（秒），防止高频重探。
    var remoteProbeCooldown: TimeInterval = 5.0

    private final class Session {
        var task: Task<Void, Never>?
        var handle: (any SSHProcessHandle)?
        var userStopped = false
        var phase: TunnelPhase = .idle
        var localVerified: Bool?
        var remoteVerified: Bool?
        var lastRemoteProbeAt: Date?
        var probingRemote = false
        var profile: ServerProfile?
        var localEndpoint: LocalProxyEndpoint?
        var effectiveMode: ConnectionMode?
        var selectionReason: String?
        var networkReachability: Bool?
        var adapterSession: RemoteHTTPAdapterSession?
        var httpAdapterVerified: Bool?
        var httpAdapterStatus: HTTPAdapterStatus = .notRequested
        var httpAdapterDetail: String?
        var relay: (any TCPRelaying)?
        var trafficID: UUID?
        /// 密码模式：本次连接的密码（仅内存；断开/退出即丢弃，不落盘不进日志）。
        /// UI 经 submitPassword 写入；setup 任务轮询此字段（不再用 continuation 挂起）。
        var password: String?
    }

    private var sessions: [UUID: Session] = [:]
    private var trafficGenerations: [UUID: UUID] = [:]
    private var trafficSequences: [UUID: UInt64] = [:]

    init(
        processFactory: any SSHProcessFactory = FoundationSSHProcessFactory(),
        localProber: any ProxyProbeExecuting = CurlProxyProbe(),
        remoteProber: any RemoteProbeExecuting,
        secrets: any PasswordStoring,
        relayFactory: (any TCPRelayMaking)? = nil,
        httpAdapterManager: (any RemoteHTTPAdapterManaging)? = nil
    ) {
        self.processFactory = processFactory
        self.localProber = localProber
        self.remoteProber = remoteProber
        self.secrets = secrets
        self.relayFactory = relayFactory
        self.httpAdapterManager = httpAdapterManager
    }

    // MARK: - TunnelService

    func connect(configuration: TunnelConfiguration) {
        let id = configuration.profile.id
        // U14：已有 setup 任务或存活进程时忽略重复请求
        if let existing = sessions[id], existing.task != nil || existing.handle?.isRunning == true {
            return
        }
        let session = Session()
        session.profile = configuration.profile
        sessions[id] = session

        session.task = Task { @MainActor [weak self] in
            await self?.runSetup(session: session, configuration: configuration)
        }
    }

    func disconnect(profileID: UUID) {
        guard let session = sessions[profileID] else { return }
        // 用户断开是终态：先置位再取消，保证后续所有路径静默（U13/I03）
        session.userStopped = true
        session.relay?.stop()
        session.task?.cancel()
        session.task = nil
        if let profile = session.profile, session.adapterSession != nil {
            scheduleAdapterCleanup(session: session, profile: profile, emitStatus: true)
        }
        if let handle = session.handle {
            handle.terminate()
            scheduleForceKill(handle)
        }
        session.handle = nil
        session.password = nil // 断开即丢弃
        session.phase = .idle
        session.localVerified = nil
        session.remoteVerified = nil
        session.networkReachability = nil

        var stopping = baseSnapshot(profileID: profileID, phase: .disconnecting)
        stopping.humanReadableDetail = "正在断开（终止本 App 启动的 SSH 进程）"
        onEvent?(.snapshot(stopping))

        var idle = baseSnapshot(profileID: profileID, phase: .idle)
        idle.humanReadableDetail = "已断开（用户手动操作）；不会自动重连"
        onEvent?(.snapshot(idle))
    }

    func runHealthCheck(profileID: UUID) {
        guard let session = sessions[profileID] else { return }
        guard session.task == nil, session.userStopped == false else { return }
        guard session.phase == .connected || session.phase == .degraded,
              let handle = session.handle, handle.isRunning else {
            // 错误/认证终态不由健康检查翻转
            return
        }
        session.task = Task { @MainActor [weak self] in
            await self?.runHealthRefresh(session: session)
        }
    }

    func runLocalHealthCheck(profileID: UUID) {
        guard let session = sessions[profileID], session.task == nil, !session.userStopped,
              session.phase == .connected || session.phase == .degraded,
              session.handle?.isRunning == true else { return }
        session.task = Task { @MainActor [weak self] in
            await self?.runHealthRefresh(session: session, includeRemote: false)
        }
    }

    func isActive(profileID: UUID) -> Bool {
        guard let session = sessions[profileID] else { return false }
        return session.task != nil || session.handle?.isRunning == true
    }

    func submitPassword(profileID: UUID, password: String, remember: Bool) {
        guard let session = sessions[profileID], !session.userStopped else { return }
        session.password = password
        if remember {
            secrets.save(password, for: profileID) // 用户勾选「记住」→ 存入钥匙串
        }
    }

    func cancelPasswordPrompt(profileID: UUID) {
        guard let session = sessions[profileID] else { return }
        session.password = nil
        // 用户放弃：等价于一次手动断开（终态，不自动重连）
        disconnect(profileID: profileID)
    }

    /// App 退出：终止全部本 App 拥有的 ssh 进程（不冒 idle 事件——UI 即将消失）。
    func terminateAllSessions() {
        for (id, session) in sessions {
            session.userStopped = true
            session.task?.cancel()
            session.task = nil
            if let profile = session.profile, session.adapterSession != nil {
                scheduleAdapterCleanup(session: session, profile: profile, emitStatus: false)
            }
            session.password = nil
            session.relay?.stop()
            if let handle = session.handle {
                handle.terminate()
                scheduleForceKill(handle)
            }
            session.handle = nil
            session.phase = .idle
            sessions[id] = nil
        }
    }

    // MARK: - 连接序列

    private func runSetup(session: Session, configuration: TunnelConfiguration) async {
        let id = configuration.profile.id
        let profile = configuration.profile

        // 1) checking：动态 SOCKS5 不依赖本地代理端口；静态/自动模式沿用真实协议探测。
        let requestedMode = profile.connectionMode
        session.effectiveMode = requestedMode
        var snap = baseSnapshot(profileID: id, phase: .checking)
        snap.humanReadableDetail = requestedMode == .reverseDynamic
            ? "动态 SOCKS5 模式：不需要本地代理端口，正在检查 SSH…"
            : (requestedMode == .automatic
                ? "自动模式：先验证配置的本地代理，未通过时切换动态 SOCKS5…"
                : "正在验证本地代理…")
        session.phase = .checking
        onEvent?(.snapshot(snap))

        var effectiveMode: ConnectionMode = requestedMode == .reverseDynamic ? .reverseDynamic : .staticForward
        var selectedEndpoint: LocalProxyEndpoint?
        var selectionReason: String?
        if requestedMode != .reverseDynamic {
            if let localEndpoint = configuration.localEndpoint {
                let localOutcome = await probeLocalEndpoint(localEndpoint)
                guard !Task.isCancelled, !session.userStopped else { return }
                if localOutcome.isVerified {
                    session.localVerified = true
                    session.localEndpoint = localEndpoint
                    selectedEndpoint = localEndpoint
                } else if requestedMode == .automatic {
                    effectiveMode = .reverseDynamic
                    session.localVerified = nil
                    session.localEndpoint = nil
                    selectionReason = "本地代理入口未通过实测（\(Self.describe(outcome: localOutcome))），自动切换到动态 SOCKS5"
                } else {
                    finishSetup(session: session, profileID: id) {
                        var degraded = self.baseSnapshot(profileID: id, phase: .degraded)
                        degraded.localProxyVerified = false
                        degraded.humanReadableDetail = "本地代理验证失败（\(Self.describe(outcome: localOutcome))）：请检查端口或改用动态 SOCKS5"
                        session.phase = .degraded
                        return degraded
                    }
                    return
                }
            } else if requestedMode == .automatic {
                effectiveMode = .reverseDynamic
                session.localVerified = nil
                session.localEndpoint = nil
                selectionReason = "未发现可用的本地 HTTP/SOCKS5 入口，自动切换到动态 SOCKS5"
            } else {
                finishSetup(session: session, profileID: id) {
                    var degraded = self.baseSnapshot(profileID: id, phase: .degraded)
                    degraded.localProxyVerified = nil // 未发现 ≠ 验证失败
                    degraded.humanReadableDetail = "静态转发需要可用的本地 HTTP/SOCKS5 代理端口；请设置本地端点或改用动态 SOCKS5"
                    session.phase = .degraded
                    return degraded
                }
                return
            }
        } else {
            session.localVerified = nil
            session.localEndpoint = nil
        }
        session.effectiveMode = effectiveMode
        session.selectionReason = selectionReason

        // 2) 前置检查（ssh 二进制 / 密钥文件）
        if let failure = Self.preflightFailure(profile: profile) {
            finishSetup(session: session, profileID: id) {
                var error = self.baseSnapshot(profileID: id, phase: .error)
                error.humanReadableDetail = failure
                session.phase = .error
                return error
            }
            return
        }

        var sshEndpoint = selectedEndpoint
        if effectiveMode == .staticForward, let localEndpoint = selectedEndpoint, let relayFactory {
            let relay = relayFactory.make(profileID: id)
            session.relay = relay
            session.trafficID = relay.sessionID
            trafficGenerations[id] = relay.sessionID
            trafficSequences[id] = 0
            onEvent?(.traffic(TrafficSnapshot(profileID: id, sessionID: relay.sessionID)))
            relay.onStatistics = { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.trafficGenerations[id] == value.sessionID else { return }
                    guard value.sequence >= (self.trafficSequences[id] ?? 0) else { return }
                    self.trafficSequences[id] = value.sequence
                    self.onEvent?(.traffic(value))
                    if !value.isRunning, self.trafficGenerations[id] == value.sessionID {
                        self.trafficGenerations[id] = nil; self.trafficSequences[id] = nil
                    }
                }
            }
            let trafficID = relay.sessionID
            relay.onFailure = { [weak self] detail in
                Task { @MainActor [weak self] in self?.relayFailed(profileID: id, trafficID: trafficID, detail: detail) }
            }
            do {
                let port = try await relay.start(port: UInt16(profile.relayPort ?? 0), target: localEndpoint)
                guard !Task.isCancelled, !session.userStopped else { relay.stop(); return }
                sshEndpoint = LocalProxyEndpoint(host: "127.0.0.1", port: Int(port), protocol: localEndpoint.protocol, origin: .manual)
            } catch {
                relay.stop()
                guard !Task.isCancelled, !session.userStopped else { return }
                finishSetup(session: session, profileID: id) {
                    session.phase = .error
                    var failure = self.baseSnapshot(profileID: id, phase: .error)
                    failure.humanReadableDetail = "本地 Relay 无法启动（端口可能被占用）：\(error.localizedDescription)"
                    return failure
                }
                return
            }
        }

        // 3) connecting：启动 ssh 进程
        var connecting = baseSnapshot(profileID: id, phase: .connecting)
        connecting.localProxyVerified = session.localVerified
        connecting.selectionReason = selectionReason
        connecting.humanReadableDetail = effectiveMode == .reverseDynamic
            ? "正在建立 SSH 反向动态 SOCKS5（Linux 127.0.0.1:\(profile.remoteSocksPort)）…\(selectionReason.map { "\n\($0)" } ?? "")"
            : "正在建立 SSH 静态反向转发…"
        session.phase = .connecting
        onEvent?(.snapshot(connecting))

        let args = SSHCommandBuilder.arguments(
            profile: profile,
            mode: effectiveMode,
            localEndpoint: sshEndpoint
        )
        let usePTY = profile.authMode == .password
        let handle = usePTY
            ? processFactory.makePTY(arguments: args, environment: SSHProcessLauncher.sshEnvironment())
            : processFactory.make(arguments: args, environment: SSHProcessLauncher.sshEnvironment())
        session.handle = handle
        let sessionID = id
        handle.onExit = { [weak self, weak handle] code in
            Task { @MainActor [weak self, weak handle] in
                guard let self, let handle, self.sessions[sessionID]?.handle === handle else { return }
                self.handleProcessExit(profileID: sessionID, exitCode: code)
            }
        }
        do {
            try handle.start()
        } catch {
            session.handle = nil
            session.relay?.stop()
            finishSetup(session: session, profileID: id) {
                var errorState = self.baseSnapshot(profileID: id, phase: .error)
                errorState.humanReadableDetail = "无法启动 SSH 进程：\(error.localizedDescription)"
                session.phase = .error
                return errorState
            }
            return
        }

        // 4a) 密码模式：等待 ssh 的密码提示 → 请 UI 输入 → 经 PTY 应答
        if usePTY {
            var prompting = baseSnapshot(profileID: id, phase: .connecting)
            prompting.localProxyVerified = session.localVerified
            prompting.humanReadableDetail = "等待输入 SSH 密码…"
            onEvent?(.snapshot(prompting))

            // 等密码提示出现（或进程退出）
            let promptDeadline = Date().addingTimeInterval(30)
            var sawPrompt = false
            while Date() < promptDeadline {
                if session.userStopped || Task.isCancelled { return }
                if handle.exitCode != nil { return } // 已退出 → handleProcessExit 分类
                if SSHProcessLauncher.hasPasswordPrompt(handle.stderrTail) {
                    sawPrompt = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !session.userStopped, !Task.isCancelled else { return }
            guard sawPrompt else {
                session.relay?.stop()
                handle.terminate()
                scheduleForceKill(handle)
                finishSetup(session: session, profileID: id) {
                    session.phase = .error
                    var error = self.baseSnapshot(profileID: id, phase: .error)
                    error.humanReadableDetail = "等待 SSH 密码提示超时：已取消本次连接"
                    return error
                }
                return
            }

            // 已记住的密码（钥匙串）：自动应答，不打扰用户
            var autoPassword: String?
            if profile.rememberPassword {
                autoPassword = secrets.load(for: id)
            }

            if let saved = autoPassword {
                handle.writePTY(saved + "\n")
                session.password = saved
            } else {
                // 请求 UI 输入，轮询等待（90 秒超时，绝不无限挂起）
                var connecting = baseSnapshot(profileID: id, phase: .connecting)
                connecting.localProxyVerified = session.localVerified
                connecting.humanReadableDetail = profile.rememberPassword
                    ? "等待输入 SSH 密码…（已记住的密码不可用，将重新询问）"
                    : "等待输入 SSH 密码…（勾选「记住」可存入本机钥匙串）"
                onEvent?(.snapshot(connecting))
                onEvent?(.passwordPromptRequested(profileID: id))

                let waitDeadline = Date().addingTimeInterval(90)
                while session.password == nil && Date() < waitDeadline {
                    if session.userStopped || Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard !session.userStopped, !Task.isCancelled else { return }
                guard let password = session.password, !password.isEmpty else {
                    session.password = nil
                    session.relay?.stop()
                    handle.terminate()
                    scheduleForceKill(handle)
                    finishSetup(session: session, profileID: id) {
                        var errorState = self.baseSnapshot(profileID: id, phase: .error)
                        errorState.humanReadableDetail = "等待密码输入超时（90 秒）：已取消本次连接，请重新点「连接」"
                        session.phase = .error
                        return errorState
                    }
                    return
                }
                handle.writePTY(password + "\n")
            }
            var connecting2 = baseSnapshot(profileID: id, phase: .connecting)
            connecting2.localProxyVerified = session.localVerified
            connecting2.humanReadableDetail = "已提交密码，正在建立 SSH 隧道…"
            onEvent?(.snapshot(connecting2))
        }

        // 4) 宽限期：进程在此窗口内退出 → 分类（转发失败/认证/网络；密码错误也在此被 NumberOfPasswordPrompts=1 快速失败）
        var waited = 0.0
        while waited < graceSeconds {
            if session.userStopped || Task.isCancelled { return }
            if handle.exitCode != nil {
                return // 退出路径由 handleProcessExit 处理并发出终态
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        guard !session.userStopped, !Task.isCancelled, handle.isRunning else { return }

        // 5) 转发已建立（ExitOnForwardFailure 保证），进行远端端到端验证
        var verifying = baseSnapshot(profileID: id, phase: .connecting)
        verifying.localProxyVerified = session.localVerified
        verifying.sshProcessRunning = true
        verifying.humanReadableDetail = "隧道已建立，正在验证远端代理…"
        onEvent?(.snapshot(verifying))

        let remoteOutcome = await remoteVerify(session: session, profile: profile)
        guard !session.userStopped, !Task.isCancelled else { return }

        session.lastRemoteProbeAt = Date()
        var finalSnap: TunnelSnapshot
        switch remoteOutcome {
        case .verified(let code):
            session.remoteVerified = true
            session.networkReachability = true
            if session.effectiveMode == .reverseDynamic && profile.httpAdapterEnabled {
                let adapterResult = await startHTTPAdapter(session: session, profile: profile)
                guard !session.userStopped, !Task.isCancelled else { return }
                session.phase = adapterResult.phase
                finalSnap = baseSnapshot(profileID: id, phase: adapterResult.phase)
                finalSnap.humanReadableDetail = adapterResult.detail
            } else {
                finalSnap = baseSnapshot(profileID: id, phase: .connected)
                finalSnap.humanReadableDetail = session.effectiveMode == .reverseDynamic
                    ? "反向动态 SOCKS5 端到端请求通过（HTTP \(code)）；Clash 出站节点尚未确认\(session.selectionReason.map { "。\($0)" } ?? "")"
                    : "远端代理已验证（HTTP \(code)）"
                if profile.httpAdapterEnabled {
                    session.httpAdapterDetail = "当前实际使用静态转发，未启动 SOCKS5 到 HTTP 适配器"
                }
                session.phase = .connected
            }
        case .remoteCurlMissing:
            session.remoteVerified = nil
            session.networkReachability = nil
            finalSnap = baseSnapshot(profileID: id, phase: .degraded)
            finalSnap.humanReadableDetail = "隧道已建立，远端缺少 curl，无法验证（未验证 ≠ 可用）"
            session.phase = .degraded
        case .authRequired(let detail):
            scheduleAdapterCleanup(session: session, profile: profile, emitStatus: false)
            session.password = nil
            session.relay?.stop()
            handle.terminate()
            scheduleForceKill(handle)
            session.handle = nil
            session.remoteVerified = nil
            finalSnap = baseSnapshot(profileID: id, phase: .authRequired)
            finalSnap.humanReadableDetail = detail
            session.phase = .authRequired
        case .notProxy, .connectionFailure, .unknown:
            scheduleAdapterCleanup(session: session, profile: profile, emitStatus: false)
            session.remoteVerified = false
            session.networkReachability = false
            finalSnap = baseSnapshot(profileID: id, phase: .degraded)
            finalSnap.humanReadableDetail = "隧道已建立，远端代理未通过验证（\(Self.describe(remote: remoteOutcome))）"
            session.phase = .degraded
        }
        finishSetup(session: session, profileID: id, emitting: { finalSnap })
    }

    /// 健康检查：复核本地 + 远端（带冷却与并发锁），只影响 connected/degraded。
    /// 每个挂起点之后都必须重新验证会话状态——用户断开 / 进程死亡的终态绝不被翻转。
    private func runHealthRefresh(session: Session, includeRemote: Bool = true) async {
        defer { session.task = nil }
        guard let profile = session.profile else { return }
        let id = profile.id
        guard let handle = session.handle, handle.isRunning else { return }
        guard session.phase == .connected || session.phase == .degraded else { return }

        // 复核本次隧道实际使用的端点（自动与手动配置均适用）。
        let requiresLocalProxy = session.effectiveMode == .staticForward
        var localOK: Bool? = requiresLocalProxy ? session.localVerified : nil
        if requiresLocalProxy, let endpoint = session.localEndpoint {
            let outcome = await probeLocalEndpoint(endpoint)
            // await 后收口：断开/取消/进程死亡/终态一概静默（U13；error 不被翻转）
            guard !session.userStopped, !Task.isCancelled,
                  session.handle?.isRunning == true,
                  session.phase == .connected || session.phase == .degraded else { return }
            localOK = outcome.isVerified
            session.localVerified = outcome.isVerified
        }

        // 远端复核（冷却 + 并发锁 + 断开守卫）
        var remoteOutcome: RemoteProbeOutcome?
        let cooled = session.lastRemoteProbeAt.map { Date().timeIntervalSince($0) >= remoteProbeCooldown } ?? true
        if includeRemote && cooled && !session.probingRemote {
            guard !session.userStopped, !Task.isCancelled,
                  session.handle?.isRunning == true else { return }
            remoteOutcome = await remoteVerify(session: session, profile: profile)
            guard !session.userStopped, !Task.isCancelled,
                  session.handle?.isRunning == true,
                  session.phase == .connected || session.phase == .degraded else { return }
            session.lastRemoteProbeAt = Date()
        }

        var snap = baseSnapshot(profileID: id, phase: session.phase)
        snap.localProxyVerified = localOK
        snap.networkReachability = session.networkReachability
        snap.sshProcessRunning = true
        if let outcome = remoteOutcome {
            switch outcome {
            case .verified(let code):
                session.remoteVerified = true
                session.networkReachability = true
                snap.humanReadableDetail = "手动检查完成：远端验证通过（HTTP \(code)）"
                if session.adapterSession != nil {
                    let adapterOK = await verifyHTTPAdapter(session: session, profile: profile)
                    guard !session.userStopped, !Task.isCancelled,
                          session.handle?.isRunning == true else { return }
                    if adapterOK == false {
                        snap.humanReadableDetail += "；HTTP 兼容入口未通过，SOCKS5 仍可用"
                    }
                }
            case .remoteCurlMissing, .unknown:
                scheduleAdapterCleanup(session: session, profile: profile, emitStatus: true, statusPrefix: "健康检查完成：远端本次无法验证")
                session.remoteVerified = nil
                session.networkReachability = nil
                snap.humanReadableDetail = "健康检查完成：远端本次无法验证，连接已降级"
            case .authRequired(let detail):
                scheduleAdapterCleanup(session: session, profile: profile, emitStatus: true, statusPrefix: detail)
                session.remoteVerified = nil
                session.phase = .authRequired
                session.password = nil
                session.relay?.stop()
                handle.terminate()
                scheduleForceKill(handle)
                session.handle = nil
                snap.sshProcessRunning = false
                snap.humanReadableDetail = detail
                if profile.authMode == .password, detail.contains("认证被拒绝"), secrets.exists(for: id) {
                    secrets.delete(for: id)
                    snap.humanReadableDetail += "；已清除记住的密码，请手动重新连接"
                }
            case .notProxy, .connectionFailure:
                scheduleAdapterCleanup(session: session, profile: profile, emitStatus: true, statusPrefix: "手动检查完成：远端验证未通过")
                session.remoteVerified = false
                session.networkReachability = false
                snap.humanReadableDetail = "手动检查完成：远端验证未通过"
            }
        } else {
            snap.humanReadableDetail = includeRemote
                ? "健康检查完成（远端探测冷却中，结论沿用上次）"
                : (requiresLocalProxy
                    ? "本地健康检查完成：\(localOK == true ? "代理可用" : "代理未通过验证")"
                    : "网络栈模式无需本地代理端口；远端验活结论保持不变")
        }

        let requiresHTTPAdapter = profile.httpAdapterEnabled && session.effectiveMode == .reverseDynamic
        let adapterOK = !requiresHTTPAdapter || session.httpAdapterVerified == true
        // 静态模式要求本地代理和远端请求都通过；动态 B+ 还要求 HTTP CONNECT 验证。
        if (!requiresLocalProxy || localOK == true) && session.remoteVerified == true && adapterOK {
            snap.phase = .connected
            session.phase = .connected
        } else if session.phase == .connected {
            snap.phase = .degraded
            session.phase = .degraded
        } else {
            snap.phase = session.phase
        }
        snap.remoteProbeVerified = session.remoteVerified
        snap.httpAdapterVerified = session.httpAdapterVerified
        snap.httpAdapterStatus = session.httpAdapterStatus
        snap.httpAdapterDetail = session.httpAdapterDetail
        onEvent?(.snapshot(snap))
    }

    // MARK: - 本地端点动态跟随（U15：代理变化无缝切换）

    /// 本地代理端点变化后的无缝切换：实测新端点 → 切 Relay 目标 → 按新协议重验远端。
    /// SSH 进程与 Relay 监听端口保持不变——这正是引入 Relay 间接层的意义。
    /// 端点相同（host/port/协议一致）时不动作，避免重复扫描触发无谓重验。
    func retargetLocalEndpoint(profileID: UUID, endpoint: LocalProxyEndpoint) {
        guard let session = sessions[profileID], session.task == nil, !session.userStopped,
              session.phase == .connected || session.phase == .degraded,
              session.effectiveMode == .staticForward,
              session.relay != nil,
              session.localEndpoint?.id != endpoint.id else { return }
        session.task = Task { @MainActor [weak self] in
            await self?.runLocalRetarget(session: session, profileID: profileID, endpoint: endpoint)
        }
    }

    private func runLocalRetarget(session: Session, profileID: UUID, endpoint: LocalProxyEndpoint) async {
        defer { session.task = nil }
        guard let profile = session.profile,
              let handle = session.handle, handle.isRunning,
              session.phase == .connected || session.phase == .degraded else { return }
        let old = session.localEndpoint

        var probing = baseSnapshot(profileID: profileID, phase: session.phase)
        probing.humanReadableDetail = "检测到本地代理端点变化（\(old?.displayEndpoint ?? "?") → \(endpoint.displayEndpoint)），正在实测新端点…"
        onEvent?(.snapshot(probing))

        // 新端点必须实测通过才切换（与连接时同一验证标准，不凭扫描结论）
        let outcome = await probeLocalEndpoint(endpoint)
        guard !session.userStopped, !Task.isCancelled,
              session.handle?.isRunning == true,
              session.phase == .connected || session.phase == .degraded else { return }

        guard outcome.isVerified else {
            var kept = baseSnapshot(profileID: profileID, phase: session.phase)
            kept.humanReadableDetail = "本地代理端点变化（\(old?.displayEndpoint ?? "?") → \(endpoint.displayEndpoint)）实测未通过（\(Self.describe(outcome: outcome))）：保持原端点，下次检测自动重试"
            onEvent?(.snapshot(kept))
            return
        }

        session.relay?.retarget(to: endpoint)
        session.localEndpoint = endpoint
        session.localVerified = true
        // 端点协议可能变化（HTTP ↔ SOCKS5）：远端既有验证结论对新协议不再成立，立即重验
        session.remoteVerified = nil
        let remoteOutcome = await remoteVerify(session: session, profile: profile)
        guard !session.userStopped, !Task.isCancelled,
              session.handle?.isRunning == true,
              session.phase == .connected || session.phase == .degraded else { return }
        session.lastRemoteProbeAt = Date()

        var snap = baseSnapshot(profileID: profileID, phase: session.phase)
        snap.localProxyVerified = true
        switch remoteOutcome {
        case .verified(let code):
            session.remoteVerified = true
            session.networkReachability = true
            session.phase = .connected
            snap.phase = .connected
            snap.humanReadableDetail = "本地代理端点变化，已无缝切换 \(old?.displayEndpoint ?? "?") → \(endpoint.displayEndpoint)（\(endpoint.protocol.displayName)）并重验远端（HTTP \(code)）；SSH 隧道未中断"
        case .remoteCurlMissing:
            session.networkReachability = nil
            session.phase = .degraded
            snap.phase = .degraded
            snap.humanReadableDetail = "本地代理已切换到 \(endpoint.displayEndpoint)；远端缺少 curl，无法重验（未验证 ≠ 可用）"
        default:
            session.remoteVerified = false
            session.networkReachability = false
            session.phase = .degraded
            snap.phase = .degraded
            snap.humanReadableDetail = "本地代理已切换到 \(endpoint.displayEndpoint)，但远端重验未通过（\(Self.describe(remote: remoteOutcome))）"
        }
        snap.remoteProbeVerified = session.remoteVerified
        onEvent?(.snapshot(snap))
    }

    // MARK: - 事件与辅助

    private func handleProcessExit(profileID: UUID, exitCode: Int32) {
        guard let session = sessions[profileID] else { return }
        guard !session.userStopped else { return } // 用户断开后的退出：静默（U13）
        // 只处理「已建立/建立中」的进程退出
        guard session.phase == .connecting || session.phase == .connected || session.phase == .degraded else { return }

        let stderr = session.handle?.stderrTail ?? ""
        let classification = SSHErrorClassifier.classify(exitCode: exitCode, stderr: stderr)
        var (phase, detail) = SSHErrorClassifier.phaseAndDetail(for: classification)
        if stderr.lowercased().contains("remote port forwarding failed"), let profile = session.profile {
            let port = session.effectiveMode == .reverseDynamic ? profile.remoteSocksPort : profile.remotePort
            detail = "远端 127.0.0.1:\(port) 监听失败：端口可能被占用或服务器禁止转发。请在服务器配置中选择其他端口或联系管理员。"
        }

        // 密码模式认证失败：给出密码语向的具体原因（而非泛化的密钥/agent 提示）
        if case .authRequired = classification,
           session.profile?.authMode == .password,
           stderr.lowercased().contains("permission denied") {
            detail = "密码认证被拒绝：密码不正确，或服务器已关闭密码登录（PasswordAuthentication no）"
            // 以钥匙串实际内容为准清除（不能用连接时捕获的旧 profile 副本判断——
            // 「记住」往往是在连接发起后才勾选的，旧副本还是 false）
            if let pid = session.profile?.id, secrets.exists(for: pid) {
                secrets.delete(for: pid)
                detail += "；已清除记住的密码，下次连接将重新询问"
            }
        }
        session.relay?.stop()
        if let profile = session.profile, session.adapterSession != nil {
            scheduleAdapterCleanup(session: session, profile: profile, emitStatus: true, statusPrefix: detail)
        }
        session.phase = phase
        session.handle = nil
        session.task?.cancel()
        session.task = nil
        session.localVerified = nil
        session.remoteVerified = nil
        session.networkReachability = nil
        session.password = nil // 进程已死，密码随之丢弃

        var snap = baseSnapshot(profileID: profileID, phase: phase)
        snap.humanReadableDetail = detail
        onEvent?(.snapshot(snap))
    }

    private func relayFailed(profileID: UUID, trafficID: UUID, detail: String) {
        guard let session = sessions[profileID], session.trafficID == trafficID, !session.userStopped else { return }
        session.task?.cancel(); session.task = nil
        session.phase = .error
        session.password = nil
        session.localVerified = nil; session.remoteVerified = nil
        if let handle = session.handle { handle.terminate(); scheduleForceKill(handle) }
        session.handle = nil
        var snapshot = baseSnapshot(profileID: profileID, phase: .error)
        snapshot.humanReadableDetail = detail
        onEvent?(.snapshot(snapshot))
    }

    private func remoteVerify(session: Session, profile: ServerProfile) async -> RemoteProbeOutcome {
        session.probingRemote = true
        defer { session.probingRemote = false }
        let port: Int
        let proxyProtocol: ProxyProtocol
        if session.effectiveMode == .reverseDynamic {
            port = profile.remoteSocksPort
            proxyProtocol = .socks5
        } else {
            port = profile.remotePort
            proxyProtocol = session.localEndpoint?.protocol ?? profile.preferredProtocol
        }
        return await remoteProber.probe(
            profile: profile,
            remotePort: port,
            protocol: proxyProtocol,
            password: session.password
        )
    }

    /// Mixed means both protocols are promised to Linux clients, so verify
    /// HTTP CONNECT and SOCKS5 separately before creating a static forward.
    private func probeLocalEndpoint(_ endpoint: LocalProxyEndpoint) async -> ProbeOutcome {
        if endpoint.protocol == .mixed {
            let http = await localProber.probe(host: endpoint.host, port: endpoint.port, protocol: .http)
            guard http.isVerified else { return http }
            return await localProber.probe(host: endpoint.host, port: endpoint.port, protocol: .socks5)
        }
        return await localProber.probe(
            host: endpoint.host,
            port: endpoint.port,
            protocol: endpoint.protocol
        )
    }

    private struct HTTPAdapterSetupResult {
        var phase: TunnelPhase
        var detail: String
    }

    private func verifyHTTPAdapter(session: Session, profile: ServerProfile) async -> Bool? {
        guard let adapter = session.adapterSession else { return session.httpAdapterVerified }
        let outcome = await remoteProber.probe(
            profile: profile,
            remotePort: profile.remoteHTTPPort,
            protocol: .http,
            password: session.password
        )
        guard !session.userStopped, !Task.isCancelled else { return nil }
        if case .verified(let code) = outcome {
            session.httpAdapterVerified = true
            session.httpAdapterStatus = .verified
            session.httpAdapterDetail = "HTTP CONNECT 已验证（HTTP \(code)）"
            return true
        }

        session.httpAdapterVerified = false
        session.httpAdapterStatus = .unavailable
        session.httpAdapterDetail = "HTTP CONNECT 健康检查失败（\(Self.describe(remote: outcome))）"
        adapter.handle.terminate()
        if let manager = httpAdapterManager {
            let cleanup = await manager.cleanup(profile: profile, session: adapter, password: session.password)
            if case .unableToConfirm(let detail) = cleanup { session.httpAdapterDetail? += "；\(detail)" }
        }
        session.adapterSession = nil
        return false
    }

    /// B+ is attempted only after the SOCKS5 path has already passed a real
    /// remote request. A failed adapter leaves the verified SOCKS5 endpoint up.
    private func startHTTPAdapter(session: Session, profile: ServerProfile) async -> HTTPAdapterSetupResult {
        session.httpAdapterStatus = .checking
        session.httpAdapterVerified = nil
        session.httpAdapterDetail = "正在检查 Linux Privoxy 与 HTTP 端口…"
        guard let manager = httpAdapterManager else {
            session.httpAdapterStatus = .unavailable
            session.httpAdapterVerified = false
            session.httpAdapterDetail = "当前构建未装配 Privoxy 管理器；远端 SOCKS5 仍可用"
            return HTTPAdapterSetupResult(phase: .degraded, detail: session.httpAdapterDetail!)
        }

        let result = await manager.start(
            profile: profile,
            httpPort: profile.remoteHTTPPort,
            socksPort: profile.remoteSocksPort,
            password: session.password
        )
        guard !Task.isCancelled, !session.userStopped else {
            if case .started(let adapter) = result {
                _ = await manager.cleanup(profile: profile, session: adapter, password: session.password)
            }
            return HTTPAdapterSetupResult(phase: .degraded, detail: "连接已取消")
        }

        switch result {
        case .started(let adapter):
            session.adapterSession = adapter
            session.httpAdapterStatus = .running
            session.httpAdapterDetail = "Privoxy 已启动，正在验证 HTTP CONNECT…"
            let httpOutcome = await remoteProber.probe(
                profile: profile,
                remotePort: profile.remoteHTTPPort,
                protocol: .http,
                password: session.password
            )
            guard !Task.isCancelled, !session.userStopped else {
                scheduleAdapterCleanup(session: session, profile: profile, emitStatus: true, statusPrefix: "连接已取消")
                return HTTPAdapterSetupResult(phase: .degraded, detail: "连接已取消")
            }
            if case .verified(let code) = httpOutcome {
                session.httpAdapterVerified = true
                session.httpAdapterStatus = .verified
                session.httpAdapterDetail = "HTTP CONNECT 已验证（HTTP \(code)）"
                return HTTPAdapterSetupResult(
                    phase: .connected,
                    detail: "动态 SOCKS5 与 Linux HTTP CONNECT 均已验证；Clash 出站节点尚未确认\(session.selectionReason.map { "。\($0)" } ?? "")"
                )
            }

            let explanation = Self.describe(remote: httpOutcome)
            let cleanup = await manager.cleanup(profile: profile, session: adapter, password: session.password)
            session.adapterSession = nil
            session.httpAdapterVerified = false
            session.httpAdapterStatus = .unavailable
            session.httpAdapterDetail = "HTTP CONNECT 验证失败（\(explanation)）；已回退到 SOCKS5"
            if case .unableToConfirm(let detail) = cleanup {
                session.httpAdapterDetail? += "；\(detail)"
            }
            return HTTPAdapterSetupResult(phase: .degraded, detail: "SOCKS5 端到端请求已验证；\(session.httpAdapterDetail ?? "HTTP 兼容入口不可用")")
        case .notInstalled:
            session.httpAdapterStatus = .notInstalled
            session.httpAdapterVerified = false
            session.httpAdapterDetail = "Linux 未安装 Privoxy；应用未安装软件。可由用户/管理员手动安装后重试；SOCKS5 入口仍可用"
        case .portConflict:
            session.httpAdapterStatus = .portConflict
            session.httpAdapterVerified = false
            session.httpAdapterDetail = "Linux HTTP 端口 127.0.0.1:\(profile.remoteHTTPPort) 已被占用；请改用其他端口"
        case .unavailable(let detail):
            session.httpAdapterStatus = .unavailable
            session.httpAdapterVerified = false
            session.httpAdapterDetail = detail
        case .authRequired(let detail):
            session.httpAdapterStatus = .unavailable
            session.httpAdapterVerified = false
            session.httpAdapterDetail = "SSH 无法管理 Privoxy：\(detail)"
        }
        return HTTPAdapterSetupResult(
            phase: .degraded,
            detail: "SOCKS5 端到端请求已验证；HTTP 兼容入口不可用：\(session.httpAdapterDetail ?? "原因未知")"
        )
    }

    /// Runs cleanup on a separate authenticated SSH command. The attached
    /// Privoxy process is terminated immediately; cleanup only confirms and
    /// removes the unique per-session user config.
    private func scheduleAdapterCleanup(
        session: Session,
        profile: ServerProfile,
        emitStatus: Bool,
        statusPrefix: String? = nil
    ) {
        guard let adapter = session.adapterSession else { return }
        session.adapterSession = nil
        session.httpAdapterStatus = .stopping
        session.httpAdapterDetail = "正在停止本 App 管理的 Privoxy 实例…"
        adapter.handle.terminate()
        scheduleForceKill(adapter.handle)
        guard let manager = httpAdapterManager else {
            session.httpAdapterStatus = .unavailable
            session.httpAdapterDetail = "已终止本地 SSH 管理进程，但无法确认远端 Privoxy 清理状态"
            return
        }
        let password = session.password
        Task { @MainActor [weak self] in
            let result = await manager.cleanup(profile: profile, session: adapter, password: password)
            session.httpAdapterVerified = nil
            switch result {
            case .stopped:
                session.httpAdapterStatus = .stopped
                session.httpAdapterDetail = "本 App 管理的 Privoxy 已停止并清理本次配置"
            case .unableToConfirm(let reason):
                session.httpAdapterStatus = .unavailable
                session.httpAdapterDetail = reason
            }
            guard emitStatus, let self else { return }
            var snapshot = self.baseSnapshot(profileID: profile.id, phase: session.phase)
            let prefix = statusPrefix ?? (session.userStopped ? "已断开" : nil)
            let cleanupDetail = session.httpAdapterDetail ?? "HTTP 入口清理状态未知"
            snapshot.humanReadableDetail = prefix.map { "\($0)；\(cleanupDetail)" } ?? cleanupDetail
            self.onEvent?(.snapshot(snapshot))
        }
    }

    private func baseSnapshot(profileID: UUID, phase: TunnelPhase) -> TunnelSnapshot {
        let session = sessions[profileID]
        return TunnelSnapshot(
            profileId: profileID,
            phase: phase,
            localProxyVerified: session?.localVerified,
            sshProcessRunning: session?.handle?.isRunning ?? false,
            remoteProbeVerified: session?.remoteVerified,
            lastRemoteProbeAt: session?.lastRemoteProbeAt,
            humanReadableDetail: "",
            effectiveMode: session?.effectiveMode,
            selectionReason: session?.selectionReason,
            activeLocalEndpoint: session?.localEndpoint,
            networkReachability: session?.networkReachability,
            clashNodeConfirmed: nil,
            httpAdapterVerified: session?.httpAdapterVerified,
            httpAdapterStatus: session?.httpAdapterStatus ?? .notRequested,
            httpAdapterDetail: session?.httpAdapterDetail
        )
    }

    /// 建立/检查任务收尾：清 task，发最终快照（profileId 由构造处保证一致）。
    private func finishSetup(session: Session, profileID: UUID, emitting snapshot: (() -> TunnelSnapshot)? = nil) {
        session.task = nil
        var snap = snapshot.map { $0() } ?? baseSnapshot(profileID: profileID, phase: session.phase)
        snap.sshProcessRunning = session.handle?.isRunning ?? false
        snap.lastRemoteProbeAt = session.lastRemoteProbeAt
        onEvent?(.snapshot(snap))
    }

    private func scheduleForceKill(_ handle: any SSHProcessHandle) {
        Task.detached { [weak handle] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let handle, handle.isRunning else { return }
            handle.forceTerminate()
        }
    }

    /// 前置检查：失败原因（nil = 通过）。
    static func preflightFailure(profile: ServerProfile) -> String? {
        if let port = profile.relayPort, !(1...65_535).contains(port) { return "Relay 端口必须在 1–65535 之间" }
        guard FileManager.default.isExecutableFile(atPath: SSHCommandBuilder.executableURL.path) else {
            return "系统缺少 /usr/bin/ssh"
        }
        if profile.authMode == .identityFile {
            let raw = profile.identityFilePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let expanded = ServerProfileRule.expandTilde(raw) ?? raw
            if expanded.isEmpty {
                return "指定私钥模式下未填写密钥路径"
            }
            if !FileManager.default.fileExists(atPath: expanded) {
                return "密钥文件不存在：\(raw)（可在终端 ssh-keygen 生成）"
            }
        }
        return nil
    }

    private static func describe(outcome: ProbeOutcome) -> String {
        switch outcome {
        case .verified: return "已验证"
        case .reachableNotProxy: return "端口可达但非代理"
        case .authRequired: return "代理要求认证"
        case .connectionRefused: return "连接被拒绝"
        case .timeout: return "超时"
        case .tlsError: return "TLS 失败"
        case .failed(let reason): return reason
        }
    }

    private static func describe(remote outcome: RemoteProbeOutcome) -> String {
        switch outcome {
        case .verified: return "已验证"
        case .notProxy(let code): return "HTTP \(code)"
        case .remoteCurlMissing: return "远端缺少 curl"
        case .authRequired(let detail): return detail
        case .connectionFailure(let reason): return reason
        case .unknown(let reason): return reason
        }
    }
}
