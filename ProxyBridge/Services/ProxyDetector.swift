import Foundation

/// 一次自动检测的产出。生产由 LocalProxyDetector 提供（SCDynamicStore + curl 实测），
/// MockProxyDetector 仅用于测试与演示。
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
    /// true = 真实读取系统设置并实测；false = Mock 演示数据。
    var isLive: Bool = false
    /// 去重后的物理端点 + 各协议能力。
    var candidates: [ProxyCandidate] = []
    /// PAC / 仅 TUN / 需认证等限制说明；空 = 无特殊限制。
    var limitations: [String] = []
    /// 系统是否报告「启用了代理」但解析不出固定端口（如 PAC）。
    var systemProxyActiveButUnresolved: Bool = false
    var lastScanAt: Date?

    /// 最佳已验证端点：preferred 协议优先，其次任一已验证。
    func bestVerifiedEndpoint(preferred: ProxyProtocol? = nil) -> LocalProxyEndpoint? {
        let verified = candidates.filter { $0.capability == .verified }
        if let p = preferred,
           let match = verified.first(where: { $0.endpoint.protocol == p })?.endpoint {
            return match
        }
        return verified.first?.endpoint
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

    /// 订阅系统代理配置变化（真实实现：SCDynamicStore 通知 + 防抖；Mock：无操作）。
    /// 返回 false 表示通知链路不可用。
    @discardableResult
    func startObservingSystemChanges() -> Bool
}

// MARK: - Mock（演示数据，绝不声称读取了系统；测试与降级演示用）

/// 演示检测器。返回固定的「示例」候选，日志与 UI 均标注演示；
/// 存在的意义是让 UI/ViewModel/持久化链路在无网络下可完整演练。
@MainActor
final class MockProxyDetector: ProxyDetectorService {
    var onStateChange: (@MainActor (ProxyDetectionState) -> Void)?

    private var state = ProxyDetectionState()
    private var task: Task<Void, Never>?

    /// 模拟耗时（秒）。
    var simulatedLatency: TimeInterval = 0.8

    func startObservingSystemChanges() -> Bool {
        // 演示模式不订阅系统变化，返回 true 保持调用方语义
        true
    }

    func detect() {
        task?.cancel()
        state.isScanning = true
        state.lastScanAt = Date()
        emit()
        task = Task { [weak self, latency = simulatedLatency] in
            try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishScan()
        }
    }

    private func finishScan() {
        state.isScanning = false
        let http = LocalProxyEndpoint(
            host: "127.0.0.1", port: 7897, protocol: .http,
            origin: .systemHTTP, verifiedAt: Date()
        )
        let socks = LocalProxyEndpoint(
            host: "127.0.0.1", port: 7897, protocol: .socks5,
            origin: .systemSOCKS, verifiedAt: Date()
        )
        state.candidates = [
            ProxyCandidate(endpoint: http, capability: .verified, note: "演示数据：未发起真实探测"),
            ProxyCandidate(endpoint: socks, capability: .verified, note: "演示数据：未发起真实探测"),
        ]
        state.limitations = [
            "当前为演示数据：未读取本机系统代理，也未发起任何网络探测。",
        ]
        state.systemProxyActiveButUnresolved = false
        emit()
    }

    private func emit() {
        onStateChange?(state)
    }
}
