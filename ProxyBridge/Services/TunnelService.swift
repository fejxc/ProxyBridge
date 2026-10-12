import Foundation

/// 隧道服务的抽象。UI 通过协议调用 SSH 隧道协调器。
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

    func runLocalHealthCheck(profileID: UUID)
    func updateRuntimeSettings(_ settings: AppSettings)
    func updateReconnectPreference(profileID: UUID, enabled: Bool, rememberPassword: Bool)
    func prepareForSleep()
    func resumeAfterWake()

    /// 该 profile 当前是否有活跃任务/进程。
    func isActive(profileID: UUID) -> Bool

    /// App 退出前清理全部本 App 拥有的子进程（PRD F05，不发 UI 事件）。
    func terminateAllSessions()

    /// 用户提交 SSH 密码（密码模式）。`remember` 为 true 时由服务写入钥匙串。
    func submitPassword(profileID: UUID, password: String, remember: Bool)

    /// 用户取消密码输入：终止本次连接尝试。
    func cancelPasswordPrompt(profileID: UUID)
}

extension TunnelService {
    func runLocalHealthCheck(profileID: UUID) { runHealthCheck(profileID: profileID) }
    func updateRuntimeSettings(_ settings: AppSettings) {}
    func updateReconnectPreference(profileID: UUID, enabled: Bool, rememberPassword: Bool) {}
    func prepareForSleep() {}
    func resumeAfterWake() {}
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
    case traffic(TrafficSnapshot)
    /// 密码模式：等待用户在 UI 输入 SSH 密码（经 PTY 应答，内存中使用、不落盘）。
    case passwordPromptRequested(profileID: UUID)
}

// MARK: - 端点解析（纯函数）

/// 解析「当前应使用的本地代理端点」。优先级（PRD F01）：
/// 用户手动指定 > 已验证的自动候选 > 未验证的回环候选（交由连接时实时探测定生死）> 未发现。
/// 注意：`.auto` 返回的端点不保证可用——协调器在连接序列里会用 curl 实测，
/// 失败照样 degraded。这样避免「启动时探测失败 → 缓存导致永远连不上」的假阴性。
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
        // 无已验证候选：回退到回环候选（可能只是上次探测时节点临时不通）
        if let fallback = detection.bestLoopbackCandidate(preferred: profile.preferredProtocol) {
            return .auto(fallback)
        }
        return .none(reason: detection.candidates.isEmpty ? "未发现本地系统代理" : "未发现回环代理候选")
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
