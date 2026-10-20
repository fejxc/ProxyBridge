import Foundation

/// 远端端口冲突的自愈闭环：自动只读诊断（带冷却）→ 呈现占用者 → 用户确认后
/// 仅清理可清理对象（同用户僵尸 sshd、自家孤儿 Privoxy）→ 释放成功自动重连。
/// 从 AppViewModel 拆出的自治协调器：持卡状态与诊断/清理流程；
/// 会话侧动作（重连、密码读取）经 attach 装配的闭包回调宿主。
@MainActor
@Observable
final class ConflictRemediationCoordinator {
    // MARK: - 依赖（注入）

    private let remoteJanitor: (any RemoteJanitorProviding)?
    private let logStore: LogStore

    init(remoteJanitor: (any RemoteJanitorProviding)?, logStore: LogStore) {
        self.remoteJanitor = remoteJanitor
        self.logStore = logStore
    }

    /// 装配需要引用宿主 ViewModel 状态的闭包（init 阶段 self 尚不可捕获，故两段式）。
    func attach(
        profile: @escaping (UUID) -> ServerProfile?,
        storedPassword: @escaping (UUID) -> String?,
        reconnect: @escaping (ServerProfile) -> Void
    ) {
        self.profile = profile
        self.storedPassword = storedPassword
        self.reconnect = reconnect
    }

    private var profile: (UUID) -> ServerProfile? = { _ in nil }
    private var storedPassword: (UUID) -> String? = { _ in nil }
    private var reconnect: (ServerProfile) -> Void = { _ in }

    // MARK: - 状态

    /// 端口冲突卡状态（nil = 无卡）。
    enum UIState: Equatable {
        case inspecting
        case unavailable(String)
        case report([RemotePortHolding])
        case cleaning
    }
    private(set) var card: (profileID: UUID, state: UIState)?
    private var inspectedAt: [UUID: Date] = [:]
    private static let inspectCooldown: TimeInterval = 60

    // MARK: - 诊断（自动 + 手动）

    /// 冲突出现时自动只读诊断（带冷却）：识别占用者，可清对象（同用户僵尸 sshd、
    /// 自家孤儿 Privoxy）呈现给用户确认。别人的进程只展示，不提供清理。
    func scheduleInspection(profileID: UUID) {
        guard remoteJanitor != nil, let profile = profile(profileID) else { return }
        guard card == nil else { return } // 已有卡片在展示，不重复诊断
        let now = Date()
        if let last = inspectedAt[profileID],
           now.timeIntervalSince(last) < Self.inspectCooldown { return }
        inspectedAt[profileID] = now
        card = (profileID, .inspecting)
        logStore.append(raw: "检测到远端端口冲突：正在经 SSH 诊断「\(profile.name)」的端口占用", level: .info, profileId: profileID)
        inspect(profile: profile, profileID: profileID)
    }

    /// 用户在卡片上点「重新诊断」。
    func reinspect() {
        guard let id = card?.profileID, let profile = profile(id) else { return }
        card = (id, .inspecting)
        inspect(profile: profile, profileID: id)
    }

    private func inspect(profile: ServerProfile, profileID: UUID) {
        guard let janitor = remoteJanitor else { return }
        var ports = [profile.remotePort, profile.remoteSocksPort]
        if profile.httpAdapterEnabled { ports.append(profile.remoteHTTPPort) }
        let password = storedPassword(profileID)
        Task { @MainActor [weak self] in
            let holdings = await janitor.inspect(profile: profile, ports: ports, password: password)
            guard let self, self.card?.profileID == profileID else { return }
            guard let holdings else {
                let hint = profile.authMode == .password && password == nil
                    ? "（密码模式且未记住密码，无法自动登录诊断）" : "（SSH 不可达或超时）"
                self.card = (profileID, .unavailable("无法自动诊断\(hint)"))
                return
            }
            if holdings.isEmpty {
                // 冲突已自愈（旧 sshd 已释放）：撤卡，常规重试会自行接上
                self.card = nil
                self.logStore.append(raw: "远端端口诊断：占用已消失（自愈），继续常规重试", level: .info, profileId: profileID)
            } else {
                self.card = (profileID, .report(holdings))
            }
        }
    }

    // MARK: - 清理

    /// 用户确认后：仅清理 kind.isCleanable 的对象（僵尸 sshd / 自家孤儿 Privoxy），
    /// 释放成功即自动重连。
    func cleanAndReconnect() {
        guard let (profileID, state) = card, case .report(let holdings) = state,
              let profile = profile(profileID),
              let janitor = remoteJanitor else { return }
        let targets = holdings.filter { $0.kind.isCleanable }
        guard !targets.isEmpty else { return }
        card = (profileID, .cleaning)
        let summary = targets.map { "\($0.port)→PID \($0.pid)（\($0.comm)）" }.joined(separator: "、")
        logStore.append(raw: "用户确认清理远端残留：\(summary)", level: .warning, profileId: profileID)
        let password = storedPassword(profileID)
        Task { @MainActor [weak self] in
            let outcome = await janitor.clean(profile: profile, targets: targets, password: password)
            guard let self else { return }
            self.card = nil
            guard let outcome else {
                self.logStore.append(raw: "远端清理执行失败（SSH 不可达）", level: .error, profileId: profileID)
                return
            }
            if outcome.allFreed {
                self.logStore.append(raw: "远端残留已清理（释放端口 \(outcome.freedPorts.map(String.init).joined(separator: "、"))），自动重连", level: .success, profileId: profileID)
                self.reconnect(profile)
            } else {
                self.logStore.append(raw: "远端清理完成但端口 \(outcome.stillHeldPorts.map(String.init).joined(separator: "、")) 仍被占用：可能是他人进程或需要更强信号，请更换端口或联系管理员", level: .warning, profileId: profileID)
            }
        }
    }

    /// 用户忽略本次诊断结果。
    func dismiss() {
        card = nil
    }

    /// 冲突恢复连接成功 → 撤卡（清理中的除外，清理流程自己收尾）。
    func withdrawIfResolved(profileID: UUID) {
        if card?.profileID == profileID, card?.state != .cleaning {
            card = nil
        }
    }

    func dropIfProfileRemoved(_ id: UUID) {
        if card?.profileID == id { card = nil }
    }

    func reset() {
        card = nil
    }
}
