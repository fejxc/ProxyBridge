import Foundation

/// 一次自动检测的产出。阶段 A 由 Mock 提供（标注 demo），
/// 阶段 B 换成 SCDynamicStore + curl 真实探测。
struct ProxyCandidate: Identifiable, Equatable, Sendable {
    var id: String { endpoint.id + "|" + capability.rawValue }
    var endpoint: LocalProxyEndpoint
    /// 每个协议的能力单独判定：可达 ≠ 协议可用（U02/U12 语义）。
    var capability: Capability

    enum Capability: String, Codable, Sendable {
        case verified    // 协议级验证通过（有网络证据）
        case reachable   // 仅 TCP 可达
        case failed      // 协议验证失败
        case untested    // 尚未探测
    }
}

/// 本地代理检测状态。
struct ProxyDetectionState: Equatable, Sendable {
    var isScanning: Bool = false
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

    /// 触发一次检测（阶段 B：读取系统代理 + 协议探测，带防抖）。
    func detect()
}

// MARK: - Mock（阶段 A：演示数据，绝不声称读取了系统）

/// 演示检测器。返回固定的「示例」候选，日志与 UI 均标注演示；
/// 存在的意义是让 UI/ViewModel/持久化链路在无网络下可完整演练。
@MainActor
final class MockProxyDetector: ProxyDetectorService {
    var onStateChange: (@MainActor (ProxyDetectionState) -> Void)?

    private var state = ProxyDetectionState()
    private var task: Task<Void, Never>?

    /// 模拟耗时（秒）。
    var simulatedLatency: TimeInterval = 0.8

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
            ProxyCandidate(endpoint: http, capability: .verified),
            ProxyCandidate(endpoint: socks, capability: .verified),
        ]
        state.limitations = [
            "当前为阶段 A 演示数据：未读取本机系统代理，也未发起任何网络探测。",
            "真实版本将读取 macOS 系统代理设置并逐协议实测（阶段 B）。",
        ]
        state.systemProxyActiveButUnresolved = false
        emit()
    }

    private func emit() {
        onStateChange?(state)
    }
}
