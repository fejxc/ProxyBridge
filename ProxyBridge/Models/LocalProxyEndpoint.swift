import Foundation

/// 本地代理协议。能力必须经真实探测确认，不能凭系统设置字段推断。
enum ProxyProtocol: String, Codable, Sendable, CaseIterable {
    case http
    case socks5

    var displayName: String {
        switch self {
        case .http: return "HTTP"
        case .socks5: return "SOCKS5"
        }
    }

    /// `curl` 的代理参数名（阶段 B 探测使用，此处先行定义保证单一来源）。
    var curlProxyFlag: String {
        switch self {
        case .http: return "--proxy"
        case .socks5: return "--socks5-hostname"
        }
    }
}

/// 端点来源。rawValue 同时是 JSON 持久化格式（02-TECHNICAL-DESIGN §3）。
enum ProxyEndpointOrigin: String, Codable, Sendable {
    case systemHTTP
    case systemHTTPS
    case systemSOCKS
    case manual

    var isManual: Bool { self == .manual }

    var displayName: String {
        switch self {
        case .systemHTTP: return "系统 HTTP 设置"
        case .systemHTTPS: return "系统 HTTPS 设置"
        case .systemSOCKS: return "系统 SOCKS 设置"
        case .manual: return "手动指定"
        }
    }
}

/// 一个具体的本地代理端点。
///
/// MVP 约束：host 只允许 loopback（127.0.0.1 / ::1 / localhost）。
/// `verifiedAt == nil` 表示从未通过协议级验证，不得当作可用。
struct LocalProxyEndpoint: Codable, Equatable, Identifiable, Sendable {
    /// 形如 `"http|127.0.0.1|7897"` 的稳定标识。
    var id: String
    var host: String
    var port: Int
    var `protocol`: ProxyProtocol
    var origin: ProxyEndpointOrigin
    var verifiedAt: Date?

    init(
        host: String,
        port: Int,
        protocol: ProxyProtocol,
        origin: ProxyEndpointOrigin,
        verifiedAt: Date? = nil
    ) {
        self.host = host
        self.port = port
        self.protocol = `protocol`
        self.origin = origin
        self.verifiedAt = verifiedAt
        self.id = Self.makeID(host: host, port: port, protocol: `protocol`)
    }

    static func makeID(host: String, port: Int, protocol: ProxyProtocol) -> String {
        "\(`protocol`.rawValue)|\(host)|\(port)"
    }

    var displayEndpoint: String { "\(host):\(port)" }
}

enum LocalProxyEndpointRule {
    /// MVP 只允许本机回环地址作为本地代理主机。
    static let allowedHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    static func isValid(host: String, port: Int) -> Bool {
        allowedHosts.contains(host.lowercased()) && (1...65_535).contains(port)
    }

    /// 校验手动输入，返回按字段分组的错误（为空即通过）。
    static func validate(host: String, port: Int) -> [String] {
        var errors: [String] = []
        if !allowedHosts.contains(host.trimmingCharacters(in: .whitespaces).lowercased()) {
            errors.append("代理地址仅支持本机回环（127.0.0.1 / ::1 / localhost）")
        }
        if !(1...65_535).contains(port) {
            errors.append("端口必须在 1–65535 之间")
        }
        return errors
    }
}
