import Foundation

/// SSH 认证方式。
/// 安全约定：`password` 模式的密码只在连接时经内存临时使用（PTY 应答 ssh 提示），
/// 绝不写入磁盘/日志/导出；模型层不设密码字段。
enum AuthenticationMode: String, Codable, Sendable, CaseIterable {
    case agent
    case identityFile
    case password

    var displayName: String {
        switch self {
        case .agent: return "ssh-agent（推荐）"
        case .identityFile: return "指定私钥文件"
        case .password: return "SSH 密码（不保存，仅连接时输入）"
        }
    }
}

/// 本地代理选择模式：自动检测失败时应显式手动，不允许默默猜测。
enum ProxySelectionMode: String, Codable, Sendable, CaseIterable {
    case automatic
    case manual

    var displayName: String {
        switch self {
        case .automatic: return "自动检测"
        case .manual: return "手动指定"
        }
    }
}

/// 一台远程服务器的连接配置（02-TECHNICAL-DESIGN §3）。
///
/// 安全约束：
/// - `remoteBindHost` 固定为 127.0.0.1，模型层不提供可修改的公开途径；
/// - `identityFilePath` 只是本机文件路径引用，绝不包含密钥内容。
struct ServerProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var sshPort: Int
    var username: String
    var authMode: AuthenticationMode
    var identityFilePath: String?
    var remotePort: Int
    var proxySelectionMode: ProxySelectionMode
    var manualEndpoint: LocalProxyEndpoint?
    var preferredProtocol: ProxyProtocol
    var reconnectEnabled: Bool
    var connectAtLaunch: Bool
    /// 密码模式：是否记住密码（密码本体存 macOS 钥匙串，绝不进本文件）。
    var rememberPassword: Bool

    /// MVP 远程绑定只允许 loopback；不提供 0.0.0.0。
    static let remoteBindHost = "127.0.0.1"

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        sshPort: Int,
        username: String,
        authMode: AuthenticationMode = .agent,
        identityFilePath: String? = nil,
        remotePort: Int,
        proxySelectionMode: ProxySelectionMode = .automatic,
        manualEndpoint: LocalProxyEndpoint? = nil,
        preferredProtocol: ProxyProtocol = .http,
        reconnectEnabled: Bool = true,
        connectAtLaunch: Bool = false,
        rememberPassword: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.sshPort = sshPort
        self.username = username
        self.authMode = authMode
        self.identityFilePath = identityFilePath
        self.remotePort = remotePort
        self.proxySelectionMode = proxySelectionMode
        self.manualEndpoint = manualEndpoint
        self.preferredProtocol = preferredProtocol
        self.reconnectEnabled = reconnectEnabled
        self.connectAtLaunch = connectAtLaunch
        self.rememberPassword = rememberPassword
    }

    var displayTarget: String { "\(username)@\(host):\(sshPort)" }
    var remoteListenDisplay: String { "\(Self.remoteBindHost):\(remotePort)" }

    enum CodingKeys: String, CodingKey {
        case id, name, host, sshPort, username, authMode, identityFilePath
        case remotePort, proxySelectionMode, manualEndpoint, preferredProtocol
        case reconnectEnabled, connectAtLaunch, rememberPassword
    }

    /// 兼容旧文件：`rememberPassword` 缺失时按 false 处理（不破坏既有 profiles.json）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        sshPort = try c.decode(Int.self, forKey: .sshPort)
        username = try c.decode(String.self, forKey: .username)
        authMode = try c.decode(AuthenticationMode.self, forKey: .authMode)
        identityFilePath = try c.decodeIfPresent(String.self, forKey: .identityFilePath)
        remotePort = try c.decode(Int.self, forKey: .remotePort)
        proxySelectionMode = try c.decode(ProxySelectionMode.self, forKey: .proxySelectionMode)
        manualEndpoint = try c.decodeIfPresent(LocalProxyEndpoint.self, forKey: .manualEndpoint)
        preferredProtocol = try c.decode(ProxyProtocol.self, forKey: .preferredProtocol)
        reconnectEnabled = try c.decode(Bool.self, forKey: .reconnectEnabled)
        connectAtLaunch = try c.decode(Bool.self, forKey: .connectAtLaunch)
        rememberPassword = try c.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? false
    }
}

// MARK: - 校验（纯函数，供表单与连接前共用）

struct ProfileValidation: Equatable, Sendable {
    var errors: [String] = []
    var warnings: [String] = []

    var isValid: Bool { errors.isEmpty }
}

enum ServerProfileRule {
    static let nameLengthLimits = 1...40
    static let usernameMaxLength = 32

    /// host / username 采用白名单字符集校验，从源头排除 shell 控制字符。
    /// 注意：MVP 暂不接受 IPv6 字面量（ssh 目的地语法不同），提示改用主机名。
    static func validateHost(_ raw: String) -> String? {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { return "SSH 主机不能为空" }
        if host.count > 253 { return "主机名过长（最多 253 字符）" }
        if host.contains(where: { $0.isWhitespace }) { return "主机不能包含空白字符" }
        if host.contains(where: { ch in !"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-".contains(ch) }) {
            return "主机仅允许字母、数字、点、连字符（IPv6 字面量暂不支持，请使用主机名）"
        }
        if isValidIPv4(host) { return nil }
        // 主机名：标签 1–63 字符，只能字母数字开头结尾，可含连字符
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.isEmpty { return "主机名格式不正确" }
        for label in labels {
            if label.isEmpty || label.count > 63 { return "主机名格式不正确" }
            let s = String(label)
            let first = s.first!, last = s.last!
            if !("a"..."z").contains(first.lowercased()) && !first.isNumber { return "主机名格式不正确" }
            if !("a"..."z").contains(last.lowercased()) && !last.isNumber { return "主机名格式不正确" }
            // 注意：允许 "--"（punycode 形如 xn--e1afmkfd 是合法 IDN 主机名）
        }
        return nil
    }

    static func isValidIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for p in parts {
            guard let v = Int(p), (0...255).contains(v), p.count <= 3, !p.isEmpty else { return false }
            if p.count > 1 && p.hasPrefix("0") { return false } // 拒绝前导零
        }
        return true
    }

    static func validateUsername(_ raw: String) -> String? {
        let user = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty { return "SSH 用户名不能为空" }
        if user.count > usernameMaxLength { return "用户名过长（最多 \(usernameMaxLength) 字符）" }
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        if !user.allSatisfy({ allowed.contains($0) }) { return "用户名仅允许字母、数字、点、下划线、连字符" }
        if !(user.first!.isLetter || user.first! == "_") { return "用户名需以字母或下划线开头" }
        return nil
    }

    /// 完整 profile 校验。错误阻止保存/连接；警告允许保存但需要用户知晓。
    static func validate(_ profile: ServerProfile) -> ProfileValidation {
        var result = ProfileValidation()

        let nameCount = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).count
        if !nameLengthLimits.contains(nameCount) {
            result.errors.append("名称长度需在 1–40 字符之间")
        }
        if let hostError = validateHost(profile.host) {
            result.errors.append(hostError)
        }
        if !(1...65_535).contains(profile.sshPort) {
            result.errors.append("SSH 端口必须在 1–65535 之间")
        }
        if let userError = validateUsername(profile.username) {
            result.errors.append(userError)
        }
        if !(1...65_535).contains(profile.remotePort) {
            result.errors.append("远程监听端口必须在 1–65535 之间")
        } else if profile.remotePort < 1024 {
            result.warnings.append("远程端口 < 1024 通常需要远端 root 权限，建议使用 1024–65535")
        }
        switch profile.authMode {
        case .agent, .password:
            break // agent 无需本地密钥；密码在连接时经内存输入（不落盘）
        case .identityFile:
            let path = (profile.identityFilePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty {
                result.errors.append("认证方式为私钥文件时必须填写密钥路径")
            } else if path.contains("\0") {
                result.errors.append("密钥路径非法")
            }
            if let expanded = Self.expandTilde(path), !FileManager.default.fileExists(atPath: expanded) {
                result.warnings.append("密钥文件当前不存在（可稍后创建，连接前必须就位）")
            }
        }
        if profile.proxySelectionMode == .manual {
            if let ep = profile.manualEndpoint {
                if !LocalProxyEndpointRule.isValid(host: ep.host, port: ep.port) {
                    result.errors.append("手动代理端点必须是本机回环地址且端口 1–65535")
                }
            } else {
                result.errors.append("手动代理模式必须填写本地代理端点")
            }
        }
        return result
    }

    /// 将 `~` 展开为当前用户主目录；路径不以 ~ 开头时原样返回。
    static func expandTilde(_ path: String) -> String? {
        guard path.hasPrefix("~") else { return path }
        let home = NSHomeDirectory()
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return nil // 形如 ~otheruser/... 的语法 MVP 不展开
    }
}
