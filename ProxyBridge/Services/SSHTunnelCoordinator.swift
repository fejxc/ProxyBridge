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
    /// HTTP 兼容入口工厂：nil = 功能不可用（测试环境）。
    private let httpEntryFactory: HTTPEntryRelayFactory?

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
        var httpAdapterVerified: Bool?
        var httpAdapterStatus: HTTPAdapterStatus = .notRequested
        var httpAdapterDetail: String?
        var relay: (any TCPRelaying)?
        var trafficID: UUID?
        /// HTTP 兼容入口（Mac 侧 HTTPEntryRelay 实现，远端零依赖）；nil = 未启用或启动失败。
        var httpEntry: (any HTTPEntryRelaying)?
        /// HTTP 入口的本地监听端口（构造 `-R` 附加转发用）。
        var httpEntryPort: UInt16?
        /// 密码模式：本次连接的密码（仅内存；断开/退出即丢弃，不落盘不进日志）。
        /// UI 经 submitPassword 写入。
        var password: String?
        /// 密码模式：本次连接的 askpass 凭据装置（认证后销毁，见 SSHAskpassCredential）。
        var askpass: SSHAskpassCredential?
        /// 用户提交密码时勾选的「记住」意图：钥匙串写入推迟到认证成功之后，
        /// 错密码不会污染持久化存储。
        var rememberPasswordRequested = false
        /// 健康检查因上一次刷新/切换任务在途而被拒时置位；任务收尾后排空，
        /// 周期不再整段丢失到下一个间隔。
        var pendingHealthCheck = false
        /// 连续业务探测硬失败数；连接重建、验证成功后复位，unknown 不计数。
        var consecutiveRemoteFailures = 0
    }

    private var sessions: [UUID: Session] = [:]
    private var trafficGenerations: [UUID: UUID] = [:]
    private var trafficSequences: [UUID: UInt64] = [:]
    /// 密码模式「会话内记忆」：认证成功后在内存保留（App 进程生命周期），
    /// 供本会话内的自动重连复用——否则每次重连都卡密码提示 90 秒，
    /// 自愈链路对密码用户实际失效。用户断开或认证被拒即清除；
    /// 与「记住密码（钥匙串）」的跨会话持久化语义不同，如实区分。
    private var sessionPasswords: [UUID: String] = [:]

    init(
        processFactory: any SSHProcessFactory = FoundationSSHProcessFactory(),
        localProber: any ProxyProbeExecuting = CurlProxyProbe(),
        remoteProber: any RemoteProbeExecuting,
        secrets: any PasswordStoring,
        relayFactory: (any TCPRelayMaking)? = nil,
        httpEntryFactory: HTTPEntryRelayFactory? = nil
    ) {
        self.processFactory = processFactory
        self.localProber = localProber
        self.remoteProber = remoteProber
        self.secrets = secrets
        self.relayFactory = relayFactory
        self.httpEntryFactory = httpEntryFactory
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
        session.password = sessionPasswords[id] // 会话内记忆：自动重连免再次询问
        sessions[id] = session

        session.task = Task { @MainActor [weak self] in
            await self?.runSetup(session: session, configuration: configuration)
        }
    }

    func disconnect(profileID: UUID) {
        performDisconnect(profileID: profileID, idleDetail: "已断开（用户手动操作）；不会自动重连")
    }

    /// 系统原因断开（网络恢复重建 / 模式升级）：行为与用户断开一致，
    /// 文案如实说明原因；调用方随后会立即重新连接。
    func disconnectForSystemReason(profileID: UUID, reason: String) {
        performDisconnect(profileID: profileID, idleDetail: "\(reason)；即将重建连接")
    }

    private func performDisconnect(profileID: UUID, idleDetail: String) {
        guard let session = sessions[profileID] else { return }
        sessionPasswords[profileID] = nil // 用户断开：会话内密码随之丢弃
        // 断开是终态：先置位再取消，保证后续所有路径静默（U13/I03）
        session.userStopped = true
        session.task?.cancel()
        session.task = nil
        teardownSessionResources(session, terminateProcess: true)
        session.password = nil // 断开即丢弃
        session.phase = .idle
        session.localVerified = nil
        session.remoteVerified = nil
        session.networkReachability = nil
        session.consecutiveRemoteFailures = 0

        var stopping = baseSnapshot(profileID: profileID, phase: .disconnecting)
        stopping.humanReadableDetail = "正在断开（终止本 App 启动的 SSH 进程）"
        onEvent?(.snapshot(stopping))

        var idle = baseSnapshot(profileID: profileID, phase: .idle)
        idle.humanReadableDetail = idleDetail
        onEvent?(.snapshot(idle))
    }

    func runHealthCheck(profileID: UUID) {
        guard let session = sessions[profileID] else { return }
        guard session.userStopped == false else { return }
        guard session.phase == .connected || session.phase == .degraded,
              let handle = session.handle, handle.isRunning else {
            // 错误/认证终态不由健康检查翻转
            return
        }
        // 上一次刷新/端点切换任务在途：登记待办，任务收尾后排空，
        // 该周期不再整段丢失到下一个间隔
        guard session.task == nil else {
            session.pendingHealthCheck = true
            return
        }
        session.task = Task { @MainActor [weak self] in
            await self?.runHealthRefresh(session: session)
        }
    }

    func runLocalHealthCheck(profileID: UUID) {
        guard let session = sessions[profileID], !session.userStopped,
              session.phase == .connected || session.phase == .degraded,
              session.handle?.isRunning == true else { return }
        // 与 runHealthCheck 同语义：在途时登记待办而非丢弃
        guard session.task == nil else {
            session.pendingHealthCheck = true
            return
        }
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
        // 「记住」不在此刻写钥匙串：认证成功（转发建立）后才落盘，
        // 输错密码 + 勾记住不会把错误密码持久化
        session.rememberPasswordRequested = remember
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
            session.password = nil
            teardownSessionResources(session, terminateProcess: true)
            session.phase = .idle
            sessions[id] = nil
        }
        sessionPasswords.removeAll() // App 退出：全部会话内密码丢弃
    }

    /// 释放会话持有的本地资源：Relay 监听器、HTTP 入口监听器、askpass 凭据文件，
    /// 并按需终止本 App 拥有的 ssh 进程。全部终态路径（用户断开、App 退出、进程退出、
    /// Relay 失败、认证被拒、启动失败、密码放弃）都必须经过这里——释放序列此前在
    /// 多处手工复制且覆盖面不一，HTTP 入口监听器曾因此在数条终态路径上泄漏。
    private func teardownSessionResources(_ session: Session, terminateProcess: Bool) {
        session.relay?.stop()
        session.httpEntry?.stop()
        session.httpEntry = nil
        session.httpEntryPort = nil
        session.askpass?.destroy()
        session.askpass = nil
        if terminateProcess, let handle = session.handle {
            handle.terminate()
            scheduleForceKill(handle)
        }
        session.handle = nil
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

        // 3) connecting：密码模式先取得密码（钥匙串 → 会话内记忆 → 请求 UI 输入），
        //    再启动 ssh——密码经 SSH_ASKPASS helper 交付（force 模式，无 PTY、
        //    无提示词刮取；等待输入发生在进程启动前，不再有 ssh 挂在提示上空转）。
        var askpass: SSHAskpassCredential?
        if profile.authMode == .password {
            var password = session.password // 会话内记忆（自动重连预填）
            if password == nil || password!.isEmpty, profile.rememberPassword {
                password = secrets.load(for: id) // 已记住的密码（钥匙串）：不打扰用户
            }
            if password == nil || password!.isEmpty {
                var prompting = baseSnapshot(profileID: id, phase: .connecting)
                prompting.localProxyVerified = session.localVerified
                prompting.humanReadableDetail = profile.rememberPassword
                    ? "等待输入 SSH 密码…（已记住的密码不可用，将重新询问）"
                    : "等待输入 SSH 密码…（勾选「记住」可存入本机钥匙串）"
                session.phase = .connecting
                onEvent?(.snapshot(prompting))
                onEvent?(.passwordPromptRequested(profileID: id))

                // 轮询等待 UI 输入（90 秒超时，绝不无限挂起）
                let waitDeadline = Date().addingTimeInterval(90)
                while (session.password == nil || session.password!.isEmpty) && Date() < waitDeadline {
                    if session.userStopped || Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                // 断开/取消优先于超时判定：断开路径已发 idle 终态并清理监听器，
                // 这里若再发「超时」错误快照，会把已断开（或重连中）的状态翻回失败
                guard !session.userStopped, !Task.isCancelled else { return }
                guard let entered = session.password, !entered.isEmpty else {
                    session.password = nil
                    // Relay 已在第 2 步启动：超时放弃必须一并释放（其余资源此刻
                    // 尚未创建，统一走清理路径保证未来新增资源不在此处泄漏）
                    teardownSessionResources(session, terminateProcess: false)
                    finishSetup(session: session, profileID: id) {
                        session.phase = .error
                        var errorState = self.baseSnapshot(profileID: id, phase: .error)
                        errorState.humanReadableDetail = "等待密码输入超时（90 秒）：已取消本次连接，请重新点「连接」"
                        return errorState
                    }
                    return
                }
                password = entered
            }
            session.password = password
            sessionPasswords[id] = password // 会话内记忆：后续自动重连复用
            guard let entered = password, let credential = SSHAskpassCredential(password: entered) else {
                teardownSessionResources(session, terminateProcess: false) // 凭据装置创建失败：释放已启动的资源
                finishSetup(session: session, profileID: id) {
                    session.phase = .error
                    var errorState = self.baseSnapshot(profileID: id, phase: .error)
                    errorState.humanReadableDetail = "无法准备 SSH 密码凭据（临时目录不可写）"
                    return errorState
                }
                return
            }
            askpass = credential
            session.askpass = credential
        }

        // 3a) HTTP 兼容入口（Mac 侧监听，远端零依赖）：必须在 ssh 启动前确定
        // 本地监听端口，才能把附加 -R 转发写进命令。静态模式按实测上游协议
        // 选 pipe/socks5 翻译；动态模式用直连（与动态 SOCKS5 的 Mac 出站语义一致）。
        var httpEntryPort: UInt16?
        if profile.httpAdapterEnabled, let httpEntryFactory {
            let entry = httpEntryFactory.make()
            // 监听器启动成功后死亡（端口被抢/系统回收）此前无上报通道，最长静默
            // 一个健康检查周期——对齐主 Relay 的 onFailure 语义，死后立即如实降级
            entry.onFailure = { [weak self] detail in
                Task { @MainActor [weak self] in
                    self?.httpEntryListenerFailed(profileID: id, detail: detail)
                }
            }
            let entryMode: HTTPEntryMode
            switch effectiveMode {
            case .staticForward:
                guard let localEndpoint = selectedEndpoint else {
                    entry.stop()
                    break
                }
                switch localEndpoint.protocol {
                case .http, .mixed: entryMode = .pipe(localEndpoint)
                case .socks5: entryMode = .socks5(localEndpoint)
                }
                do {
                    let port = try await entry.start(port: 0, mode: entryMode)
                    httpEntryPort = port
                    session.httpEntry = entry
                    session.httpEntryPort = port
                    session.httpAdapterStatus = .running
                    session.httpAdapterDetail = "HTTP 兼容入口已启动（应用内实现，远端零依赖）"
                } catch {
                    entry.stop()
                    session.httpAdapterStatus = .unavailable
                    session.httpAdapterVerified = false
                    session.httpAdapterDetail = "HTTP 兼容入口无法启动（\(error.localizedDescription)）；主转发不受影响"
                }
            case .reverseDynamic:
                do {
                    let port = try await entry.start(port: 0, mode: .direct)
                    httpEntryPort = port
                    session.httpEntry = entry
                    session.httpEntryPort = port
                    session.httpAdapterStatus = .running
                    session.httpAdapterDetail = "HTTP 兼容入口已启动（应用内实现，远端零依赖）"
                } catch {
                    entry.stop()
                    session.httpAdapterStatus = .unavailable
                    session.httpAdapterVerified = false
                    session.httpAdapterDetail = "HTTP 兼容入口无法启动（\(error.localizedDescription)）；动态 SOCKS5 不受影响"
                }
            case .automatic:
                break
            }
        }

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
            localEndpoint: sshEndpoint,
            httpEntryLocalPort: httpEntryPort
        )
        let handle = processFactory.make(
            arguments: args,
            environment: SSHProcessLauncher.sshEnvironment(credential: askpass)
        )
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
            teardownSessionResources(session, terminateProcess: false)
            finishSetup(session: session, profileID: id) {
                var errorState = self.baseSnapshot(profileID: id, phase: .error)
                errorState.humanReadableDetail = "无法启动 SSH 进程：\(error.localizedDescription)"
                session.phase = .error
                return errorState
            }
            return
        }

        // 4) 宽限期：认证与转发在此窗口内完成；进程退出 → 分类
        //（转发失败/认证/网络；错密码经 NumberOfPasswordPrompts=1 快速失败）
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
        // 认证已通过（ExitOnForwardFailure 下进程存活即转发已建立 ⇒ 认证完成）：
        // 「记住」此刻才写钥匙串——错密码路径（进程退出）永远走不到这里
        if session.rememberPasswordRequested, let password = session.password {
            session.rememberPasswordRequested = false
            if !secrets.save(password, for: id) {
                // 保存失败：KeychainStore 已留 OSLog；界面在下次连接时会因
                // 钥匙串无记录重新询问（rememberPassword 标志与实际状态偏差可自愈）
            }
        }
        // 凭据文件销毁时机：不能按宽限期猜——高延迟链路（TCP 连接本身可合法
        // 耗时 ConnectTimeout=10 秒）在宽限期结束时认证可能尚未开始，此刻销毁
        // 会让 askpass 读到空串、认证失败，还会误清钥匙串记住的密码。改为在
        // 首次远端验证结束后销毁（转发已建立 ⇒ 认证必然完成）；进程退出、断开、
        // 认证被拒等路径仍即刻销毁，崩溃残留由 >1 小时清扫兜底。

        // 5) 转发已建立（ExitOnForwardFailure 保证），进行远端端到端验证
        var verifying = baseSnapshot(profileID: id, phase: .connecting)
        verifying.localProxyVerified = session.localVerified
        verifying.sshProcessRunning = true
        verifying.humanReadableDetail = "隧道已建立，正在验证远端代理…"
        onEvent?(.snapshot(verifying))

        let remoteOutcome = await remoteVerifyWithReadinessRetry(session: session, profile: profile)
        guard !session.userStopped, !Task.isCancelled else { return }
        session.askpass?.destroy()
        session.askpass = nil

        session.lastRemoteProbeAt = Date()
        var finalSnap: TunnelSnapshot
        switch remoteOutcome {
        case .verified(let code):
            session.remoteVerified = true
            session.networkReachability = true
            session.consecutiveRemoteFailures = 0
            // HTTP 兼容入口已随连接启动（Mac 侧监听）：立即做一次端到端 CONNECT 验证。
            // 失败不影响已验证的主路径（静态转发 / 动态 SOCKS5），如实降级展示。
            if profile.httpAdapterEnabled, session.httpEntry != nil {
                let httpOK = await verifyHTTPEntry(session: session, profile: profile)
                guard !session.userStopped, !Task.isCancelled else { return }
                session.phase = httpOK ? .connected : .degraded
                finalSnap = baseSnapshot(profileID: id, phase: session.phase)
                finalSnap.humanReadableDetail = httpOK
                    ? (session.effectiveMode == .reverseDynamic
                        ? "动态 SOCKS5 与 HTTP CONNECT 入口均已验证；Clash 出站节点尚未确认\(session.selectionReason.map { "。\($0)" } ?? "")"
                        : "远端代理与 HTTP CONNECT 入口均已验证（HTTP \(code)）")
                    : session.httpAdapterDetail ?? "HTTP 入口验证失败；主路径仍可用"
            } else {
                finalSnap = baseSnapshot(profileID: id, phase: .connected)
                finalSnap.humanReadableDetail = session.effectiveMode == .reverseDynamic
                    ? "反向动态 SOCKS5 端到端请求通过（HTTP \(code)）；Clash 出站节点尚未确认\(session.selectionReason.map { "。\($0)" } ?? "")"
                    : "远端代理已验证（HTTP \(code)）"
                if profile.httpAdapterEnabled, session.httpEntry == nil,
                   session.httpAdapterStatus == .notRequested {
                    session.httpAdapterDetail = "HTTP 兼容入口未启动（当前构建未装配）"
                }
                session.phase = .connected
            }
        case .remoteCurlMissing:
            session.remoteVerified = nil
            session.networkReachability = nil
            finalSnap = baseSnapshot(profileID: id, phase: .degraded)
            finalSnap.humanReadableDetail = "隧道已建立，远端缺少 curl，无法验证（未验证 ≠ 可用）"
            finalSnap.remoteCurlMissing = true
            session.phase = .degraded
        case .authRequired(let detail):
            session.password = nil
            teardownSessionResources(session, terminateProcess: true)
            session.remoteVerified = nil
            finalSnap = baseSnapshot(profileID: id, phase: .authRequired)
            finalSnap.humanReadableDetail = detail
            session.phase = .authRequired
        case .notProxy, .connectionFailure, .unknown:
            session.remoteVerified = false
            session.networkReachability = false
            if remoteOutcome.isHardBusinessFailure {
                session.consecutiveRemoteFailures += 1
            }
            finalSnap = baseSnapshot(profileID: id, phase: .degraded)
            finalSnap.humanReadableDetail = "隧道已建立，远端代理未通过验证（\(Self.describe(remote: remoteOutcome))）"
            session.phase = .degraded
        }
        finishSetup(session: session, profileID: id, emitting: { finalSnap })
    }

    /// 健康检查：复核本地 + 远端（带冷却与并发锁），只影响 connected/degraded。
    /// 每个挂起点之后都必须重新验证会话状态——用户断开 / 进程死亡的终态绝不被翻转。
    private func runHealthRefresh(session: Session, includeRemote: Bool = true) async {
        defer {
            session.task = nil
            drainPendingHealthCheck(session: session)
        }
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
                session.consecutiveRemoteFailures = 0
                snap.humanReadableDetail = "手动检查完成：远端验证通过（HTTP \(code)）"
                if session.httpEntry != nil {
                    let entryOK = await verifyHTTPEntry(session: session, profile: profile)
                    guard !session.userStopped, !Task.isCancelled,
                          session.handle?.isRunning == true else { return }
                    if entryOK == false {
                        snap.humanReadableDetail += "；HTTP 入口未通过，主路径仍可用"
                    }
                }
            case .remoteCurlMissing, .unknown:
                session.remoteVerified = nil
                session.networkReachability = nil
                snap.remoteCurlMissing = outcome == .remoteCurlMissing
                snap.humanReadableDetail = "健康检查完成：远端本次无法验证，连接已降级"
            case .authRequired(let detail):
                session.remoteVerified = nil
                session.phase = .authRequired
                session.password = nil
                teardownSessionResources(session, terminateProcess: true)
                snap.sshProcessRunning = false
                snap.humanReadableDetail = detail
                if profile.authMode == .password, detail.contains("认证被拒绝"), secrets.exists(for: id) {
                    secrets.delete(for: id)
                    snap.humanReadableDetail += "；已清除记住的密码，请手动重新连接"
                }
            case .notProxy, .connectionFailure:
                session.remoteVerified = false
                session.networkReachability = false
                if outcome.isHardBusinessFailure {
                    session.consecutiveRemoteFailures += 1
                }
                snap.humanReadableDetail = "手动检查完成：远端验证未通过（\(Self.describe(remote: outcome))）"
            }
        } else {
            snap.humanReadableDetail = includeRemote
                ? "健康检查完成（远端探测冷却中，结论沿用上次）"
                : (requiresLocalProxy
                    ? "本地健康检查完成：\(localOK == true ? "代理可用" : "代理未通过验证")"
                    : "网络栈模式无需本地代理端口；远端验活结论保持不变")
        }

        let requiresHTTPAdapter = profile.httpAdapterEnabled && session.httpEntry != nil
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
        snap.consecutiveRemoteFailures = session.consecutiveRemoteFailures
        snap.httpAdapterVerified = session.httpAdapterVerified
        snap.httpAdapterStatus = session.httpAdapterStatus
        snap.httpAdapterDetail = session.httpAdapterDetail
        onEvent?(.snapshot(snap))
    }

    /// 排空被在途任务推迟的健康检查（见 runHealthCheck 的 pending 登记）。
    private func drainPendingHealthCheck(session: Session) {
        guard session.pendingHealthCheck else { return }
        session.pendingHealthCheck = false
        guard session.task == nil, !session.userStopped,
              session.phase == .connected || session.phase == .degraded,
              session.handle?.isRunning == true else { return }
        session.task = Task { @MainActor [weak self] in
            await self?.runHealthRefresh(session: session)
        }
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
        defer {
            session.task = nil
            drainPendingHealthCheck(session: session)
        }
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
        // HTTP 入口的上游与主 Relay 同源：端点协议可能翻转（HTTP ↔ SOCKS5），
        // 入口模式须随之重定向，否则无缝切换后入口仍指向旧上游
        if session.httpEntry != nil {
            let entryMode: HTTPEntryMode
            switch endpoint.protocol {
            case .http, .mixed: entryMode = .pipe(endpoint)
            case .socks5: entryMode = .socks5(endpoint)
            }
            session.httpEntry?.retarget(to: entryMode)
            // 新上游下入口验证结论不再成立，与健康检查一并重验
            session.httpAdapterVerified = nil
        }
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
            snap.remoteCurlMissing = true
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

    /// HTTP 入口监听器在启动成功后死亡：如实降级呈现并释放引用，
    /// 主转发路径（静态转发 / 动态 SOCKS5）不受影响。
    private func httpEntryListenerFailed(profileID: UUID, detail: String) {
        guard let session = sessions[profileID], session.httpEntry != nil, !session.userStopped else { return }
        session.httpEntry = nil
        session.httpEntryPort = nil
        session.httpAdapterVerified = false
        session.httpAdapterStatus = .unavailable
        session.httpAdapterDetail = "HTTP 入口监听器异常退出（\(detail)）；主转发路径不受影响"
        var snap = baseSnapshot(profileID: profileID, phase: session.phase)
        snap.humanReadableDetail = session.httpAdapterDetail ?? "HTTP 入口监听器异常退出；主转发路径不受影响"
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
            // sshd 原话形如 "remote port forwarding failed for listen port 7890"：
            // 失败的可能是主转发，也可能是 HTTP 入口的附加转发，按行内端口精确归因
            var failedPort = session.effectiveMode == .reverseDynamic ? profile.remoteSocksPort : profile.remotePort
            if let range = stderr.range(of: "listen port ") {
                let digits = stderr[range.upperBound...].prefix(while: { $0.isNumber })
                if let reported = Int(digits),
                   [profile.remotePort, profile.remoteSocksPort, profile.remoteHTTPPort].contains(reported) {
                    failedPort = reported
                }
            }
            detail = "远端 127.0.0.1:\(failedPort) 监听失败：端口可能被占用或服务器禁止转发。最常见原因是上一次连接的 sshd 尚未释放端口（通常 1–3 分钟内自行恢复）；开启自动重连后应用会在几分钟内自动重试。持续失败请在服务器配置中更换端口，或联系管理员检查 sshd 的 AllowTcpForwarding/PermitListen。"
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
        teardownSessionResources(session, terminateProcess: false) // 进程已自行退出，无需终止
        session.phase = phase
        session.task?.cancel()
        session.task = nil
        session.localVerified = nil
        session.remoteVerified = nil
        session.networkReachability = nil
        session.password = nil // 进程已死，密码随之丢弃
        // 认证类失败：会话内记忆一并作废（凭据有问题，重连须重新询问，防错密码循环）
        if case .authRequired = classification {
            sessionPasswords[profileID] = nil
        }

        var snap = baseSnapshot(profileID: profileID, phase: phase)
        snap.humanReadableDetail = detail
        // 原始错误透传：我们的解读是注释，不是替换——sshd 的原话一并呈现，避免
        // 翻译层丢失关键信息（v1.5.1 前的「端口占用」误导即源于此）
        if let rawLine = SSHErrorClassifier.mostInformativeLine(stderr: stderr),
           !detail.contains(rawLine) {
            snap.humanReadableDetail += "；sshd 原话：\u{201C}\(LogRedaction.sanitize(rawLine))\u{201D}"
        }
        // 首次连接（known_hosts 无记录）：标记 UI 可用的 TOFU 引导
        if case .hostKeyUnknown = classification {
            snap.hostKeyNeedsTrust = true
        }
        onEvent?(.snapshot(snap))
    }

    private func relayFailed(profileID: UUID, trafficID: UUID, detail: String) {
        guard let session = sessions[profileID], session.trafficID == trafficID, !session.userStopped else { return }
        session.task?.cancel(); session.task = nil
        session.phase = .error
        session.password = nil
        teardownSessionResources(session, terminateProcess: true)
        session.localVerified = nil; session.remoteVerified = nil
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
            password: session.password,
            urlString: profile.probeTargetURL // 用户配置的业务目标；nil 回落固定目标
        )
    }

    /// 动态 SOCKS5 的「监听就绪」竞态消化：ssh 认证完成 ≠ 远端转发端口已开始
    /// 监听（真实日志：首次验证恒 curl exit 7，约 30 秒后即通过）。对连接类失败
    /// （exit 7 拒绝）做短退避重试，最多 2 次，避免把建立期竞态误报为「部分可用」。
    /// 只消化 connectionFailure；超时/TLS 等其他失败如实立即呈现。
    private func remoteVerifyWithReadinessRetry(session: Session, profile: ServerProfile) async -> RemoteProbeOutcome {
        var delay: UInt64 = 1_500_000_000
        for attempt in 0...2 {
            let outcome = await remoteVerify(session: session, profile: profile)
            guard !session.userStopped, !Task.isCancelled,
                  session.handle?.isRunning == true else { return outcome }
            if case .connectionFailure = outcome, attempt < 2 {
                try? await Task.sleep(nanoseconds: delay)
                delay *= 2
                continue
            }
            return outcome
        }
        return .unknown(reason: "unreachable")
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

    /// HTTP 兼容入口（Mac 侧监听）的端到端 CONNECT 验证：从 Linux 经
    /// `127.0.0.1:<remoteHTTPPort>` 发真实请求。入口是本地监听器，验证失败
    /// 不需要任何远端清理，也不影响已验证的主路径（静态转发 / 动态 SOCKS5）。
    private func verifyHTTPEntry(session: Session, profile: ServerProfile) async -> Bool {
        session.httpAdapterStatus = .checking
        let outcome = await remoteProber.probe(
            profile: profile,
            remotePort: profile.remoteHTTPPort,
            protocol: .http,
            password: session.password,
            urlString: profile.probeTargetURL
        )
        guard !session.userStopped, !Task.isCancelled else { return false }
        if case .verified(let code) = outcome {
            session.httpAdapterVerified = true
            session.httpAdapterStatus = .verified
            session.httpAdapterDetail = "HTTP CONNECT 已验证（HTTP \(code)）"
            return true
        }
        session.httpAdapterVerified = false
        session.httpAdapterStatus = .unavailable
        session.httpAdapterDetail = "HTTP CONNECT 验证失败（\(Self.describe(remote: outcome))）；主路径仍可用"
        return false
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
            httpAdapterDetail: session?.httpAdapterDetail,
            consecutiveRemoteFailures: session?.consecutiveRemoteFailures ?? 0
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
