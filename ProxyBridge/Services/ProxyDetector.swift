import Foundation

/// 一次自动检测的产出。生产由 LocalProxyDetector 提供（SCDynamicStore + curl 实测），
/// 测试替身仅编入测试目标。
struct ProxyCandidate: Identifiable, Equatable, Sendable {
    /// 稳定标识（仅物理端点 + 协议）：能力/备注更新时 SwiftUI ForEach 身份不漂移。
    var id: String { endpoint.id }
    var endpoint: LocalProxyEndpoint
    /// 每个协议的能力单独判定：可达 ≠ 协议可用（U02/U12 语义）。
    var capability: Capability
    /// 本次判定的证据/原因说明（如「curl 实测通过（HTTP 200）」「407」）。
    var note: String?

    enum Capability: String, Codable, Sendable {
        case verified    // 协议级验证通过（有网络证据）
        case reachable   // 端口有响应但不是该协议可用代理
        case failed      // 探测失败（拒绝/超时/认证等）
        case untested    // 尚未探测（或 MVP 不探测，如非回环）
    }
}

/// 本地代理检测状态。
struct ProxyDetectionState: Equatable, Sendable {
    var isScanning: Bool = false
    /// true = 真实读取系统设置并实测；false = 尚未使用系统检测器。
    var isLive: Bool = false
    /// 去重后的物理端点 + 各协议能力。
    var candidates: [ProxyCandidate] = []
    /// PAC / 仅 TUN / 需认证等限制说明；空 = 无特殊限制。
    var limitations: [String] = []
    /// 系统是否报告「启用了代理」但解析不出固定端口（如 PAC）。
    var systemProxyActiveButUnresolved: Bool = false
    /// 当前经最佳已验证端点观测到的出口 IP（节点切换指纹）；nil = 未探测到（如实）。
    var egressIP: String?
    var lastScanAt: Date?

    /// 最佳已验证端点：系统来源优先于环境变量，同一来源再按 preferred 协议选择。
    func bestVerifiedEndpoint(preferred: ProxyProtocol? = nil) -> LocalProxyEndpoint? {
        let verified = candidates.filter { $0.capability == .verified }
        guard let highestPriority = verified.map({ $0.endpoint.origin.sourcePriority }).min() else { return nil }
        let preferredSource = verified.filter { $0.endpoint.origin.sourcePriority == highestPriority }
        if let p = preferred,
           let match = preferredSource.first(where: { $0.endpoint.protocol == p })?.endpoint {
            return match
        }
        return preferredSource.first?.endpoint
    }

    /// 最佳回环候选（不限验证状态）：preferred 协议优先，其次未测试 > 可达 > 失败。
    /// 供连接时实时探测回退使用（探测失败依然会在协调器中如实降级）。
    func bestLoopbackCandidate(preferred: ProxyProtocol? = nil) -> LocalProxyEndpoint? {
        let loopback = candidates.filter { ProxyCandidateBuilder.isLoopback($0.endpoint.host) }
        guard !loopback.isEmpty else { return nil }
        guard let highestPriority = loopback.map({ $0.endpoint.origin.sourcePriority }).min() else { return nil }
        let preferredSource = loopback.filter { $0.endpoint.origin.sourcePriority == highestPriority }
        if let p = preferred,
           let match = preferredSource.first(where: { $0.endpoint.protocol == p })?.endpoint {
            return match
        }
        return preferredSource.first?.endpoint
    }

    var verifiedCandidates: [ProxyCandidate] {
        candidates.filter { $0.capability == .verified }
    }
}

/// 本地代理检测服务抽象。
@MainActor
protocol ProxyDetectorService: AnyObject {
    var onStateChange: (@MainActor (ProxyDetectionState) -> Void)? { get set }

    /// 触发一次检测（读取系统代理 + 协议探测）。
    func detect()

    /// 订阅系统代理配置变化（SCDynamicStore 通知 + 防抖）。
    /// 返回 false 表示通知链路不可用。
    @discardableResult
    func startObservingSystemChanges() -> Bool
}
