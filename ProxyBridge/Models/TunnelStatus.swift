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
            return StatusPresentation(title: "未连接", detail: "点击连接以建立转发", tone: .gray)
        case .checking:
            return StatusPresentation(title: "检查中", detail: "正在验证本地代理…", tone: .blue)
        case .connecting, .reconnecting:
            let verb = snapshot.phase == .reconnecting ? "正在重连" : "正在建立 SSH 隧道…"
            return StatusPresentation(title: snapshot.phase == .reconnecting ? "重连中" : "连接中", detail: verb, tone: .blue)
        case .connected:
            if snapshot.remoteProbeVerified == true {
                return StatusPresentation(title: "已连接", detail: "远端代理已验证", tone: .green)
            }
            // connected 但远端未验证属于不一致状态，按降级呈现，不显示全绿
            return StatusPresentation(title: "部分可用", detail: "隧道已建立，远端代理未验证", tone: .orange)
        case .degraded:
            if snapshot.localProxyVerified == false {
                return StatusPresentation(title: "代理异常", detail: "本地代理未通过验证", tone: .orange)
            }
            return StatusPresentation(title: "部分可用", detail: snapshot.humanReadableDetail, tone: .orange)
        case .authRequired:
            return StatusPresentation(title: "需要处理", detail: "检查服务器指纹或 SSH 密钥", tone: .red)
        case .error:
            return StatusPresentation(title: "连接失败", detail: snapshot.humanReadableDetail.isEmpty ? "发生错误，请查看日志" : snapshot.humanReadableDetail, tone: .red)
        case .disconnecting:
            return StatusPresentation(title: "断开中", detail: "正在停止 SSH 进程…", tone: .blue)
        }
    }

    /// 三层健康行的展示映射。SSH 层结合进程存活与相共同判断。
    static func healthTriad(for snapshot: TunnelSnapshot) -> (local: HealthCheckDisplay, ssh: HealthCheckDisplay, remote: HealthCheckDisplay) {
        let local = tri(from: snapshot.localProxyVerified)

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
}
