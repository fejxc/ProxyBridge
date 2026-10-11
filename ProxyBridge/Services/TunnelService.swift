import Foundation

/// 隧道服务的抽象。UI 只认识这个协议；阶段 A 由 MockTunnelService 演示，
/// 阶段 C 由真实 SSH 进程管理器实现。协议演进以真实实现为准。
@MainActor
protocol TunnelService: AnyObject {
    /// 服务→UI 的事件回调。事件按 profile 分组，乱序由实现方保证不发生。
    var onEvent: (@MainActor (TunnelEvent) -> Void)? { get set }

    /// 请求建立隧道（含前置本地代理检查）。已在进行中的 profile 再次调用应被忽略（U14）。
    func connect(configuration: TunnelConfiguration)

    /// 用户请求断开：取消在途任务、终止属于该 profile 的进程（阶段 C），
    /// 之后只允许发出 disconnecting → idle，绝不再自动重连（U13）。
    func disconnect(profileID: UUID)

    /// 手动「检查连接」：只做验证，不改配置。
    func runHealthCheck(profileID: UUID)

    /// 该 profile 当前是否有活跃任务/进程。
    func isActive(profileID: UUID) -> Bool

    /// App 退出前清理全部本 App 拥有的子进程（PRD F05，不发 UI 事件）。
    func terminateAllSessions()
}

/// 传给隧道服务的一份完整连接描述。
struct TunnelConfiguration: Sendable, Equatable {
    var profile: ServerProfile
    /// 已解析的本地代理端点（manual 优先，其次已验证的自动候选）。nil = 未解析。
    var localEndpoint: LocalProxyEndpoint?
}

/// 隧道服务向 UI 上报的事件。
enum TunnelEvent: Sendable {
    case snapshot(TunnelSnapshot)
}

// MARK: - 端点解析（纯函数）

/// 解析「当前应使用的本地代理端点」。优先级（PRD F01）：
/// 用户手动指定 > 可验证且当前系统启用的代理 > 未发现。
/// 返回值只包含已通过验证的端点；未验证的自动候选不会顶替手动配置。
enum EndpointResolver {
    enum Resolved: Equatable, Sendable {
        case manual(LocalProxyEndpoint)
        case auto(LocalProxyEndpoint)
        case none(reason: String)
    }

    static func resolve(profile: ServerProfile, detection: ProxyDetectionState) -> Resolved {
        if profile.proxySelectionMode == .manual {
            if let manual = profile.manualEndpoint {
                return .manual(manual)
            }
            return .none(reason: "手动模式未填写端点")
        }
        if let best = detection.bestVerifiedEndpoint(preferred: profile.preferredProtocol) {
            return .auto(best)
        }
        return .none(reason: detection.candidates.isEmpty ? "未发现本地系统代理" : "候选端点未通过协议验证")
    }

    /// 展示用描述（面板「本地代理」行）。
    static func describe(_ resolved: Resolved, preferred: ProxyProtocol) -> String {
        switch resolved {
        case .manual(let ep):
            return "手动指定 · \(ep.displayEndpoint) · \(ep.protocol.displayName)"
        case .auto(let ep):
            return "自动检测 · \(ep.displayEndpoint) · \(ep.protocol.displayName)"
        case .none(let reason):
            return reason
        }
    }
}
