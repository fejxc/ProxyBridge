import Foundation
import SystemConfiguration

// MARK: - 系统代理快照（02-TECHNICAL-DESIGN §4.1）

/// 系统代理设置的只读快照（SCDynamicStoreCopyProxies 的解析结果）。
/// 注意：`HTTPSEnable` 的含义是「访问 HTTPS 网站时经此代理」，
/// 到代理本身的协议仍是 HTTP CONNECT——它不产生独立的「HTTPS 代理协议」候选。
struct SystemProxySnapshot: Equatable, Sendable {
    struct ExplicitProxy: Equatable, Sendable {
        var host: String
        var port: Int
    }

    var http: ExplicitProxy?
    var https: ExplicitProxy?
    var socks: ExplicitProxy?
    var pacEnabled = false
    var pacURL: String?
    var autoDiscoveryEnabled = false

    var hasAnyExplicitProxy: Bool {
        http != nil || https != nil || socks != nil
    }
}

/// 系统代理读取抽象（测试注入；实现只读，绝不修改系统设置）。
protocol SystemProxyProviding: AnyObject, Sendable {
    func readProxies() -> SystemProxySnapshot
}

/// 从 SCDynamicStore 读取当前系统代理。
final class SCDynamicStoreProxyProvider: SystemProxyProviding {
    init() {}

    func readProxies() -> SystemProxySnapshot {
        guard let dict = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return SystemProxySnapshot()
        }
        return Self.parse(dict)
    }

    /// 纯解析（可单测）：容错 CFNumber/CFString 混排；
    /// 端口 0 / 越界 / 空 host 一律视为未配置。
    static func parse(_ dict: [String: Any]) -> SystemProxySnapshot {
        var snapshot = SystemProxySnapshot()

        func enabled(_ key: String) -> Bool {
            if let n = dict[key] as? Int { return n == 1 }
            if let b = dict[key] as? Bool { return b }
            return false
        }
        func text(_ key: String) -> String? {
            guard let s = dict[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        func number(_ key: String) -> Int? {
            if let n = dict[key] as? Int { return n }
            if let s = dict[key] as? String { return Int(s) }
            return nil
        }
        func proxy(hostKey: String, portKey: String) -> SystemProxySnapshot.ExplicitProxy? {
            guard let host = text(hostKey),
                  let port = number(portKey),
                  (1...65_535).contains(port) else { return nil }
            return SystemProxySnapshot.ExplicitProxy(host: host, port: port)
        }

        if enabled("HTTPEnable") {
            snapshot.http = proxy(hostKey: "HTTPProxy", portKey: "HTTPPort")
        }
        if enabled("HTTPSEnable") {
            snapshot.https = proxy(hostKey: "HTTPSProxy", portKey: "HTTPSPort")
        }
        if enabled("SOCKSEnable") {
            snapshot.socks = proxy(hostKey: "SOCKSProxy", portKey: "SOCKSPort")
        }
        snapshot.pacEnabled = enabled("ProxyAutoConfigEnable")
        snapshot.pacURL = text("ProxyAutoConfigURLString")
        snapshot.autoDiscoveryEnabled = enabled("ProxyAutoDiscoveryEnable")
        return snapshot
    }
}

// MARK: - 候选构建（纯函数，U01–U04）

/// 由系统快照构建去重后的待测候选。
/// 规则（PRD F01 / 技术设计 §4.1）：
/// - 先去重物理端点，再按协议分别实测（同 host:port 的 HTTP+SOCKS 保留两条待测）；
/// - 同 host:port 同协议（来自 HTTP 与 HTTPS 字段）只保留一条，来源优先 systemHTTP；
/// - PAC 模式不生成固定端口候选，标注限制；
/// - 非 loopback 候选仅显示，MVP 不探测也不转发。
enum ProxyCandidateBuilder {
    struct Built: Equatable, Sendable {
        var candidates: [ProxyCandidate]
        var limitations: [String]
    }

    static func build(from snapshot: SystemProxySnapshot) -> Built {
        var limitations: [String] = []

        // 按来源优先级顺序追加（systemHTTP > systemHTTPS > systemSOCKS），
        // 去重时 first-write-wins 即实现优先级。
        var entries: [LocalProxyEndpoint] = []
        if let p = snapshot.http {
            entries.append(LocalProxyEndpoint(host: p.host, port: p.port, protocol: .http, origin: .systemHTTP))
        }
        if let p = snapshot.https {
            entries.append(LocalProxyEndpoint(host: p.host, port: p.port, protocol: .http, origin: .systemHTTPS))
        }
        if let p = snapshot.socks {
            entries.append(LocalProxyEndpoint(host: p.host, port: p.port, protocol: .socks5, origin: .systemSOCKS))
        }

        var byKey: [String: LocalProxyEndpoint] = [:]
        for endpoint in entries where byKey[endpoint.id] == nil {
            byKey[endpoint.id] = endpoint
        }

        var candidates = byKey.values
            .map { ProxyCandidate(endpoint: $0, capability: .untested) }
            .sorted { $0.id < $1.id }

        // 非 loopback：显示但 MVP 不探测、不转发
        for index in candidates.indices where !isLoopback(candidates[index].endpoint.host) {
            candidates[index].note = "非本机回环地址：MVP 不自动探测与转发；确认安全后可在服务器配置中手动指定"
        }

        if snapshot.pacEnabled {
            limitations.append("系统启用了 PAC 自动配置脚本（\(snapshot.pacURL ?? "URL 未提供")）：无法从中解析出固定代理端口，App 不会替你套用脚本决策；如脚本固定返回某端口，请手动指定。")
        }
        if candidates.isEmpty && !snapshot.pacEnabled {
            limitations.append("未从 macOS 系统设置解析到已启用的代理端口。若代理客户端处于 TUN/增强模式（无本地监听端口），本工具无法为其建立转发；请切换回端口模式，或在下方手动指定。")
        }
        return Built(candidates: candidates, limitations: limitations)
    }

    /// 回环判定（发现候选用，比手动输入校验更宽）：
    /// 覆盖 127.0.0.0/8、::1 及其展开形式、localhost；其余视为非回环。
    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" || h == "[::1]" || h == "0:0:0:0:0:0:0:1" {
            return true
        }
        // 127.0.0.0/8：四段点分且首段 127
        if h.hasPrefix("127.") {
            let rest = h.dropFirst(4).split(separator: ".", omittingEmptySubsequences: false)
            if rest.count == 4, rest.allSatisfy({ !($0.isEmpty) && Int($0) != nil && Int($0)! <= 255 }) {
                return true
            }
        }
        return false
    }
}
