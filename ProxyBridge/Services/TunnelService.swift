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

    /// 系统原因（网络恢复重建 / 模式升级）的断开：语义与 disconnect 相同
    /// （终态、清进程、取消任务），仅提示文案不同；随后由调用方立即重连。
    func disconnectForSystemReason(profileID: UUID, reason: String)

    /// 手动「检查连接」：只做验证，不改配置。
    func runHealthCheck(profileID: UUID)

    /// 本地代理端点变化后，把活跃静态转发的 Relay 无缝切到新端点
    /// （实测新端点 → 切换目标 → 重验远端；SSH 进程不重启）。
    func retargetLocalEndpoint(profileID: UUID, endpoint: LocalProxyEndpoint)

    func runLocalHealthCheck(profileID: UUID)
    func updateRuntimeSettings(_ settings: AppSettings)
    func updateReconnectPreference(profileID: UUID, enabled: Bool, rememberPassword: Bool)
    func prepareForSleep()
    func resumeAfterWake()
    /// 网络路径恢复：绕过退避立即重连允许自动重连的会话（默认无操作）。
    func handleNetworkRestoration()

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
    func retargetLocalEndpoint(profileID: UUID, endpoint: LocalProxyEndpoint) {}
    func disconnectForSystemReason(profileID: UUID, reason: String) { disconnect(profileID: profileID) }
    func updateRuntimeSettings(_ settings: AppSettings) {}
    func updateReconnectPreference(profileID: UUID, enabled: Bool, rememberPassword: Bool) {}
    func prepareForSleep() {}
    func resumeAfterWake() {}
    func handleNetworkRestoration() {}
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

/// 解析「当前应尝试的本地代理端点」。优先级：
/// 用户手动指定 > 已验证候选 > 其他可信配置的回环候选。未验证候选在连接时会再次实测；
/// 静态模式失败时保持失败，自动连接模式由协调器回退到反向动态 SOCKS5。
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
