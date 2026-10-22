import Foundation

/// 隧道状态机的相（02-TECHNICAL-DESIGN §6）。
enum TunnelPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case checking
    case connecting
    case connected
    case degraded
    case reconnecting
    case authRequired
    case error
    case disconnecting
}

/// HTTP 兼容入口状态（App 内实现后仅剩本地监听与端到端验证两类结论）。
enum HTTPAdapterStatus: String, Codable, Sendable, CaseIterable {
    case notRequested
    case checking
    case running
    case verified
    case unavailable
}

/// 当前自愈策略只覆盖“SSH 存活但远端业务通路连续失败”；
/// 后续分层探测扩展时再增加本机出口、HTTP 入口等作用域。
enum TunnelFaultScope: String, Sendable, Equatable {
    case remotePath

    var displayName: String {
        switch self {
        case .remotePath: return L10n.t("远端业务通路")
        }
    }
}

enum TunnelRecoveryAction: String, Sendable, Equatable {
    case rebuildTunnel
    case probeOnly

    var displayName: String {
        switch self {
        case .rebuildTunnel: return L10n.t("受控重建隧道")
        case .probeOnly: return L10n.t("只继续探测")
        }
    }
}

enum TunnelRecoveryState: String, Sendable, Equatable {
    case scheduled
    case executed
    case succeeded
    case budgetExhausted

    var displayName: String {
        switch self {
        case .scheduled: return L10n.t("已排程")
        case .executed: return L10n.t("已执行")
        case .succeeded: return L10n.t("已恢复")
        case .budgetExhausted: return L10n.t("预算用尽")
        }
    }
}

extension TunnelRecoveryState {
    var healthDisplay: HealthCheckDisplay {
        switch self {
        case .scheduled, .executed: return .unknown
        case .succeeded: return .ok
        case .budgetExhausted: return .failed
        }
    }
}

/// 一次自愈决策的可解释记录。它不是故障本身，只说明策略选择了什么动作。
struct TunnelRecoveryDecision: Equatable, Sendable {
    let scope: TunnelFaultScope
    let action: TunnelRecoveryAction
    let state: TunnelRecoveryState
    let reason: String
    let decidedAt: Date
    let nextActionAt: Date?
    let consecutiveFailures: Int
    let remainingRecoveries: Int

    func succeeded(at date: Date = Date()) -> TunnelRecoveryDecision {
        TunnelRecoveryDecision(
            scope: scope,
            action: action,
            state: .succeeded,
            reason: reason,
            decidedAt: date,
            nextActionAt: nil,
            consecutiveFailures: 0,
            remainingRecoveries: remainingRecoveries
        )
    }

    func executed(at date: Date = Date()) -> TunnelRecoveryDecision {
        TunnelRecoveryDecision(
            scope: scope,
            action: action,
            state: .executed,
            reason: reason,
            decidedAt: date,
            nextActionAt: nil,
            consecutiveFailures: consecutiveFailures,
            remainingRecoveries: remainingRecoveries
        )
    }
}

/// 单个 profile 的隧道状态快照。
///
/// 三态语义（重要）：`localProxyVerified` / `remoteProbeVerified` 为 `Bool?`：
/// - `nil`   = 未验证（无法断言成败）
/// - `false` = 已验证失败
/// - `true`  = 已验证成功
/// 任何地方都不得把 `nil` 当作 `true` 处理。
struct TunnelSnapshot: Equatable, Sendable {
    let profileId: UUID
    var phase: TunnelPhase
    var localProxyVerified: Bool?
    var sshProcessRunning: Bool
    var remoteProbeVerified: Bool?
    var lastRemoteProbeAt: Date?
    var humanReadableDetail: String
    /// The selected working mode after automatic resolution. A SOCKS port is
    /// never inferred from or labelled as an HTTP endpoint.
    var effectiveMode: ConnectionMode? = nil
    var selectionReason: String? = nil
    var activeLocalEndpoint: LocalProxyEndpoint? = nil
    var networkReachability: Bool? = nil
    /// No automated probe can prove which Clash rule/node handled this traffic.
    var clashNodeConfirmed: Bool? = nil
    var httpAdapterVerified: Bool? = nil
    var httpAdapterStatus: HTTPAdapterStatus = .notRequested
    var httpAdapterDetail: String? = nil
    /// 首次连接且 known_hosts 无记录：应用内 TOFU 引导可用（主机密钥变化时不置位）。
    var hostKeyNeedsTrust: Bool = false
    /// 远端缺少 curl：端到端验证被阻塞，UI 提供安装指引（缺 Privoxy 走 httpAdapterStatus）。
    var remoteCurlMissing: Bool = false
    /// 连续业务探测硬失败次数；unknown/缺 curl 属不确定，不计数。
    var consecutiveRemoteFailures: Int = 0
    /// 最近一次策略决策；由运行时策略层附加，协调器只负责故障证据。
    var lastRecoveryDecision: TunnelRecoveryDecision? = nil
    /// 最近的状态迁移，给面板展示“为什么走到这一步”；只保留短环形历史。
    var recoveryHistory: [TunnelRecoveryDecision] = []

    static func idle(_ profileId: UUID) -> TunnelSnapshot {
        TunnelSnapshot(
            profileId: profileId,
            phase: .idle,
            localProxyVerified: nil,
            sshProcessRunning: false,
            remoteProbeVerified: nil,
            lastRemoteProbeAt: nil,
            humanReadableDetail: "未连接"
        )
    }

    /// `connected` 严格表示最近一次端到端远端验证成功；
    /// 远端未验证时即使 SSH 存活也只能是 degraded。
    var isEndToEndVerified: Bool {
        phase == .connected && remoteProbeVerified == true
    }

    mutating func appendRecoveryDecision(_ decision: TunnelRecoveryDecision, limit: Int = 6) {
        recoveryHistory.append(decision)
        if recoveryHistory.count > limit {
            recoveryHistory.removeFirst(recoveryHistory.count - limit)
        }
        lastRecoveryDecision = decision
    }
}

// MARK: - 展示层映射（纯函数，便于单测）

/// 状态色调。菜单栏图标与状态标签共用，颜色之外永远有文本。
enum StatusTone: String, Codable, Sendable {
    case gray    // 未连接 / 未发现
    case blue    // 连接中
    case green   // 全部验证通过
    case orange  // 降级 / 部分可用
    case red     // 错误 / 需要处理
}

/// 三层健康检查里每一层的展示状态。
enum HealthCheckDisplay: String, Sendable {
    case ok       // ✓ 已验证
    case unknown  // ! 未验证
    case failed   // · 失败

    var symbolName: String {
        switch self {
        case .ok: return "checkmark"
        case .unknown: return "exclamationmark"
        case .failed: return "minus"
        }
    }

    var tone: StatusTone {
        switch self {
        case .ok: return .green
        case .unknown: return .orange
        case .failed: return .red
        }
    }
}

struct RecoveryDecisionPresentation: Equatable {
    var title: String
    var detail: String
    var display: HealthCheckDisplay
}

struct StatusPresentation: Equatable, Sendable {
    var title: String
    var detail: String
    var tone: StatusTone
}

enum TunnelStatusPresentation {
    /// 快照 → 面板主状态（文案对应 03-UI-SPEC §2.1 状态表与 02-TECHNICAL-DESIGN §10）。
    static func overall(for snapshot: TunnelSnapshot) -> StatusPresentation {
        switch snapshot.phase {
        case .idle:
            return StatusPresentation(title: L10n.t("未连接"), detail: L10n.t("点击连接以建立转发"), tone: .gray)
        case .checking:
            let detail = snapshot.effectiveMode == .reverseDynamic
                ? L10n.t("动态 SOCKS5 模式不需要本地代理端口")
                : (snapshot.humanReadableDetail.isEmpty ? L10n.t("正在检查连接方式…") : snapshot.humanReadableDetail)
            return StatusPresentation(title: L10n.t("检查中"), detail: detail, tone: .blue)
        case .connecting, .reconnecting:
            let verb = snapshot.phase == .reconnecting ? L10n.t("正在重连") : L10n.t("正在建立 SSH 隧道…")
            let detail = snapshot.humanReadableDetail.isEmpty ? verb : snapshot.humanReadableDetail
            return StatusPresentation(title: snapshot.phase == .reconnecting ? L10n.t("重连中") : L10n.t("连接中"), detail: detail, tone: .blue)
        case .connected:
            if snapshot.remoteProbeVerified == true {
                let detail = snapshot.humanReadableDetail.isEmpty ? L10n.t("远端代理已验证") : snapshot.humanReadableDetail
                return StatusPresentation(title: L10n.t("已连接"), detail: detail, tone: .green)
            }
            // connected 但远端未验证属于不一致状态，按降级呈现，不显示全绿
            return StatusPresentation(title: L10n.t("部分可用"), detail: L10n.t("隧道已建立，远端代理未验证"), tone: .orange)
        case .degraded:
            if snapshot.effectiveMode != .reverseDynamic && snapshot.localProxyVerified == false {
                return StatusPresentation(title: L10n.t("代理异常"), detail: L10n.t("本地代理未通过验证"), tone: .orange)
            }
            if snapshot.effectiveMode != .reverseDynamic && snapshot.localProxyVerified == nil {
                // 端点从未验证成功且当前不可用：UI-SPEC「没有系统代理候选」→ 未发现代理
                let detail = snapshot.humanReadableDetail.isEmpty
                    ? L10n.t("确认代理客户端运行中，重新点「连接」或手动指定端口")
                    : snapshot.humanReadableDetail
                return StatusPresentation(title: L10n.t("未发现代理"), detail: detail, tone: .orange)
            }
            return StatusPresentation(title: L10n.t("部分可用"), detail: snapshot.humanReadableDetail, tone: .orange)
        case .authRequired:
            let specific = snapshot.humanReadableDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            return StatusPresentation(
                title: L10n.t("需要处理"),
                detail: specific.isEmpty ? L10n.t("检查服务器指纹或 SSH 密钥") : specific,
                tone: .red
            )
        case .error:
            return StatusPresentation(title: L10n.t("连接失败"), detail: snapshot.humanReadableDetail.isEmpty ? L10n.t("发生错误，请查看日志") : snapshot.humanReadableDetail, tone: .red)
        case .disconnecting:
            return StatusPresentation(title: L10n.t("断开中"), detail: L10n.t("正在停止 SSH 进程…"), tone: .blue)
        }
    }

    /// 三层健康行的展示映射。SSH 层结合进程存活与相共同判断。
    static func healthTriad(for snapshot: TunnelSnapshot) -> (local: HealthCheckDisplay, ssh: HealthCheckDisplay, remote: HealthCheckDisplay) {
        let local = snapshot.effectiveMode == .reverseDynamic
            ? tri(from: snapshot.networkReachability)
            : tri(from: snapshot.localProxyVerified)

        let ssh: HealthCheckDisplay
        switch snapshot.phase {
        case .connected, .degraded, .reconnecting:
            ssh = snapshot.sshProcessRunning ? .ok : .failed
        case .connecting, .checking, .disconnecting:
            ssh = .unknown
        case .idle:
            ssh = .failed
        case .authRequired, .error:
            ssh = .failed
        }

        let remote = tri(from: snapshot.remoteProbeVerified)
        return (local, ssh, remote)
    }

    private static func tri(from value: Bool?) -> HealthCheckDisplay {
        switch value {
        case .some(true): return .ok
        case .some(false): return .failed
        case .none: return .unknown
        }
    }

    /// 把自愈决策翻译成面板行；无决策时返回 nil，面板不占位。
    static func recoveryDecision(for snapshot: TunnelSnapshot, now: Date = Date()) -> RecoveryDecisionPresentation? {
        guard let decision = snapshot.lastRecoveryDecision else { return nil }
        let display: HealthCheckDisplay
        switch decision.state {
        case .scheduled, .executed: display = .unknown
        case .succeeded: display = .ok
        case .budgetExhausted: display = .failed
        }

        var parts = ["\(decision.scope.displayName) · \(decision.action.displayName) · \(decision.state.displayName)"]
        if decision.consecutiveFailures > 0 {
            parts.append(String(format: L10n.t("连续失败 %d 次"), decision.consecutiveFailures))
        }
        if let next = decision.nextActionAt, decision.state == .scheduled {
            let seconds = max(0, Int(next.timeIntervalSince(now).rounded()))
            parts.append(String(format: L10n.t("%d 秒后执行"), seconds))
        }
        if decision.remainingRecoveries >= 0 {
            parts.append(String(format: L10n.t("剩余重建预算 %d 次"), decision.remainingRecoveries))
        }
        if !decision.reason.isEmpty {
            parts.append(decision.reason)
        }
        return RecoveryDecisionPresentation(
            title: L10n.t("自愈决策"),
            detail: parts.joined(separator: "；"),
            display: display
        )
    }
}
