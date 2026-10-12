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
        /// 密码模式：本次连接的密码（仅内存；断开/退出即丢弃，不落盘不进日志）。
        var password: String?
        var passwordContinuation: CheckedContinuation<String?, Never>?
    }

    private var sessions: [UUID: Session] = [:]

    init(
        processFactory: any SSHProcessFactory = FoundationSSHProcessFactory(),
        localProber: any ProxyProbeExecuting = CurlProxyProbe(),
        remoteProber: any RemoteProbeExecuting,
        secrets: any PasswordStoring
    ) {
        self.processFactory = processFactory
        self.localProber = localProber
        self.remoteProber = remoteProber
        self.secrets = secrets
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
        session.password = nil // 断开即丢弃
        session.passwordContinuation?.resume(returning: nil)
        session.passwordContinuation = nil
        session.task?.cancel()
        session.task = nil
        if let handle = session.handle {
            handle.terminate()
            scheduleForceKill(handle)
        }
        session.handle = nil

        var stopping = baseSnapshot(profileID: profileID, phase: .disconnecting)
        stopping.humanReadableDetail = "正在断开（终止本 App 启动的 SSH 进程）"
        onEvent?(.snapshot(stopping))

        var idle = TunnelSnapshot.idle(profileID)
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
        session.passwordContinuation?.resume(returning: password)
        session.passwordContinuation = nil
    }

    func cancelPasswordPrompt(profileID: UUID) {
        guard let session = sessions[profileID] else { return }
        session.password = nil
        session.passwordContinuation?.resume(returning: nil)
        session.passwordContinuation = nil
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
            session.passwordContinuation?.resume(returning: nil)
            session.passwordContinuation = nil
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

        // 1) checking：本地代理验证（nil/false 语义严格区分）
        var snap = baseSnapshot(profileID: id, phase: .checking)
        snap.humanReadableDetail = "正在验证本地代理…"
        session.phase = .checking
        onEvent?(.snapshot(snap))

        guard let localEndpoint = configuration.localEndpoint else {
            finishSetup(session: session, profileID: id) {
                var degraded = self.baseSnapshot(profileID: id, phase: .degraded)
                degraded.localProxyVerified = nil // 未发现 ≠ 验证失败
                degraded.humanReadableDetail = "未发现可用的本地代理端点：请确认代理客户端正在运行且系统代理已开启，然后重新点「连接」；或在「本地代理」页手动指定端口"
                session.phase = .degraded
                return degraded
            }
            return
        }
        let localOutcome = await localProber.probe(
            host: localEndpoint.host,
            port: localEndpoint.port,
            protocol: localEndpoint.protocol
        )
        guard !Task.isCancelled, !session.userStopped else { return }
        guard localOutcome.isVerified else {
            finishSetup(session: session, profileID: id) {
                var degraded = self.baseSnapshot(profileID: id, phase: .degraded)
                degraded.localProxyVerified = false
                degraded.humanReadableDetail = "本地代理验证失败（\(Self.describe(outcome: localOutcome))）：请确认代理运行或改用手动配置"
                session.phase = .degraded
                return degraded
            }
            return
        }
        session.localVerified = true

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

        // 3) connecting：启动 ssh 进程
        var connecting = baseSnapshot(profileID: id, phase: .connecting)
        connecting.localProxyVerified = true
        connecting.humanReadableDetail = "正在建立 SSH 隧道…"
        session.phase = .connecting
        onEvent?(.snapshot(connecting))

        let args = SSHCommandBuilder.arguments(profile: profile, localEndpoint: localEndpoint)
        let usePTY = profile.authMode == .password
        let handle = usePTY
            ? processFactory.makePTY(arguments: args, environment: SSHProcessLauncher.sshEnvironment())
            : processFactory.make(arguments: args, environment: SSHProcessLauncher.sshEnvironment())
        session.handle = handle
        let sessionID = id
        handle.onExit = { [weak self] code in
            Task { @MainActor in
                self?.handleProcessExit(profileID: sessionID, exitCode: code)
            }
        }
        do {
            try handle.start()
        } catch {
            session.handle = nil
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
            prompting.localProxyVerified = true
            prompting.humanReadableDetail = "等待输入 SSH 密码…"
            onEvent?(.snapshot(prompting))

            // 等密码提示出现（或进程退出）
            let promptDeadline = Date().addingTimeInterval(30)
            var sawPrompt = false
            while Date() < promptDeadline {
                if session.userStopped || Task.isCancelled { return }
                if handle.exitCode != nil { return } // 已退出 → handleProcessExit 分类
                if handle.stderrTail.lowercased().contains("password") {
                    sawPrompt = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !session.userStopped, !Task.isCancelled else { return }
            guard sawPrompt else { return } // 超时/退出已由其他路径处理

            // 已记住的密码（钥匙串）：自动应答，不打扰用户
            var autoPassword: String?
            if profile.rememberPassword {
                autoPassword = secrets.load(for: id)
            }

            if let saved = autoPassword {
                handle.writePTY(saved + "\n")
                session.password = saved
            } else {
                // 请求 UI 输入并挂起等待
                var connecting = baseSnapshot(profileID: id, phase: .connecting)
                connecting.localProxyVerified = true
                connecting.humanReadableDetail = profile.rememberPassword
                    ? "等待输入 SSH 密码…（已记住的密码不可用，将重新询问）"
                    : "等待输入 SSH 密码…（勾选「记住」可存入本机钥匙串）"
                onEvent?(.snapshot(connecting))
                onEvent?(.passwordPromptRequested(profileID: id))

                let submitted = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    session.passwordContinuation = continuation
                }
                guard !session.userStopped, !Task.isCancelled else { return }
                guard let password = submitted, !password.isEmpty else {
                    session.password = nil
                    return // cancelPasswordPrompt 已发出 disconnecting→idle
                }
                handle.writePTY(password + "\n")
            }
            var connecting2 = baseSnapshot(profileID: id, phase: .connecting)
            connecting2.localProxyVerified = true
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
        verifying.localProxyVerified = true
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
            finalSnap = baseSnapshot(profileID: id, phase: .connected)
            finalSnap.humanReadableDetail = "远端代理已验证（HTTP \(code)）"
            session.phase = .connected
        case .remoteCurlMissing:
            session.remoteVerified = nil
            finalSnap = baseSnapshot(profileID: id, phase: .degraded)
            finalSnap.humanReadableDetail = "隧道已建立，远端缺少 curl，无法验证（未验证 ≠ 可用）"
            session.phase = .degraded
        case .authRequired(let detail):
            session.remoteVerified = nil
            finalSnap = baseSnapshot(profileID: id, phase: .authRequired)
            finalSnap.humanReadableDetail = detail
            session.phase = .authRequired
        case .notProxy, .connectionFailure, .unknown:
            session.remoteVerified = false
            finalSnap = baseSnapshot(profileID: id, phase: .degraded)
            finalSnap.humanReadableDetail = "隧道已建立，远端代理未通过验证（\(Self.describe(remote: remoteOutcome))）"
            session.phase = .degraded
        }
        finishSetup(session: session, profileID: id, emitting: { finalSnap })
    }

    /// 健康检查：复核本地 + 远端（带冷却与并发锁），只影响 connected/degraded。
    /// 每个挂起点之后都必须重新验证会话状态——用户断开 / 进程死亡的终态绝不被翻转。
    private func runHealthRefresh(session: Session) async {
        defer { session.task = nil }
        guard let profile = session.profile else { return }
        let id = profile.id
        guard let handle = session.handle, handle.isRunning else { return }
        guard session.phase == .connected || session.phase == .degraded else { return }

        // 本地复核（用当前解析到的手动端点；自动候选的复核由代理检测层负责）
        var localOK = session.localVerified == true
        if let endpoint = resolvedEndpoint(of: profile) {
            let outcome = await localProber.probe(
                host: endpoint.host, port: endpoint.port, protocol: endpoint.protocol
            )
            // await 后收口：断开/取消/进程死亡/终态一概静默（U13；error 不被翻转）
            guard !session.userStopped, !Task.isCancelled,
                  session.handle?.isRunning == true,
                  session.phase == .connected || session.phase == .degraded else { return }
            localOK = outcome.isVerified
            session.localVerified = localOK
        }

        // 远端复核（冷却 + 并发锁 + 断开守卫）
        var remoteOutcome: RemoteProbeOutcome?
        let cooled = session.lastRemoteProbeAt.map { Date().timeIntervalSince($0) >= remoteProbeCooldown } ?? true
        if cooled && !session.probingRemote {
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
        snap.sshProcessRunning = true
        if let outcome = remoteOutcome {
            switch outcome {
            case .verified(let code):
                session.remoteVerified = true
                snap.humanReadableDetail = "手动检查完成：远端验证通过（HTTP \(code)）"
            case .remoteCurlMissing, .unknown:
                if session.remoteVerified != true { session.remoteVerified = nil }
                snap.humanReadableDetail = "手动检查完成：远端本次无法验证（结论沿用上次）"
            case .notProxy, .connectionFailure, .authRequired:
                session.remoteVerified = false
                snap.humanReadableDetail = "手动检查完成：远端验证未通过"
            }
        } else {
            snap.humanReadableDetail = "手动检查完成（远端探测冷却中，结论沿用上次）"
        }

        // 相位重算（基于复查后的会话状态）：三层全绿才 connected；任一失败降级（不保留旧绿）
        if localOK && session.remoteVerified == true {
            snap.phase = .connected
            session.phase = .connected
        } else if session.phase == .connected {
            snap.phase = .degraded
            session.phase = .degraded
        } else {
            snap.phase = session.phase
        }
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

        // 密码模式认证失败：给出密码语向的具体原因（而非泛化的密钥/agent 提示）
        if case .authRequired = classification,
           session.profile?.authMode == .password {
            detail = "密码认证被拒绝：密码不正确，或服务器已关闭密码登录（PasswordAuthentication no）"
            if session.profile?.rememberPassword == true {
                if let pid = session.profile?.id {
                    secrets.delete(for: pid)
                }
                detail += "；已清除记住的密码，下次连接将重新询问"
            }
        }
        session.phase = phase
        session.handle = nil
        session.task?.cancel()
        session.task = nil
        session.localVerified = nil
        session.remoteVerified = nil
        session.password = nil // 进程已死，密码随之丢弃

        var snap = baseSnapshot(profileID: profileID, phase: phase)
        snap.humanReadableDetail = detail
        onEvent?(.snapshot(snap))
    }

    private func remoteVerify(session: Session, profile: ServerProfile) async -> RemoteProbeOutcome {
        session.probingRemote = true
        defer { session.probingRemote = false }
        return await remoteProber.probe(
            profile: profile,
            remotePort: profile.remotePort,
            protocol: profile.preferredProtocol,
            password: session.password
        )
    }

    private func resolvedEndpoint(of profile: ServerProfile) -> LocalProxyEndpoint? {
        profile.manualEndpoint
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
            humanReadableDetail: ""
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
