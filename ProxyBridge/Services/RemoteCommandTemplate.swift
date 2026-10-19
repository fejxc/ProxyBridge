import Foundation

/// 生成「远端使用代理」的可复制命令（纯函数、无副作用）。
/// 端口只接受 Int；内容全部来自受控常量，不拼接用户自由文本。
enum RemoteCommandTemplate {

    /// 远端缺失、需要用户自行安装的依赖（App 不安装软件、不用 sudo）。
    enum RemoteTool: String, CaseIterable, Sendable {
        case curl
        case privoxy

        var displayName: String { self == .curl ? "curl" : "Privoxy" }
    }

    /// 安装指引：覆盖常见发行版；只生成命令，执行由用户决定。
    static func installHintCommands(component: RemoteTool) -> String {
        switch component {
        case .curl:
            return """
            # ProxyBridge 需要在服务器上用 curl 做端到端验证（App 不会替你安装）
            # Debian / Ubuntu：
            sudo apt-get install -y curl
            # RHEL / CentOS / Fedora（旧系统把 dnf 换成 yum）：
            sudo dnf install -y curl
            """
        case .privoxy:
            return """
            # HTTP 兼容入口（Codex HTTP_PROXY）依赖服务器上的 Privoxy；App 不会替你安装
            # Debian / Ubuntu：
            sudo apt-get install -y privoxy
            # RHEL / CentOS / Fedora（旧系统把 dnf 换成 yum）：
            sudo dnf install -y privoxy
            """
        }
    }

    static func socksProbeCommand(remotePort: Int) -> String? {
        guard (1...65_535).contains(remotePort) else { return nil }
        return "curl --socks5-hostname 127.0.0.1:\(remotePort) -I --connect-timeout 8 --max-time 20 https://api.openai.com/v1/models"
    }

    static func httpCompatibilityCommands(remotePort: Int) -> String? {
        guard (1...65_535).contains(remotePort) else { return nil }
        return """
        export http_proxy=http://127.0.0.1:\(remotePort)
        export https_proxy=http://127.0.0.1:\(remotePort)
        export HTTP_PROXY=http://127.0.0.1:\(remotePort)
        export HTTPS_PROXY=http://127.0.0.1:\(remotePort)
        export NO_PROXY=localhost,127.0.0.1,::1
        curl -I --proxy http://127.0.0.1:\(remotePort) --connect-timeout 8 --max-time 20 https://api.openai.com/v1/models
        """
    }

    static func dynamicClipboardText(
        socksPort: Int,
        httpPort: Int,
        includeHTTPAdapter: Bool,
        socksVerified: Bool?,
        httpVerified: Bool?
    ) -> String? {
        guard let socksCheck = socksProbeCommand(remotePort: socksPort) else { return nil }
        var text = """
        # Linux SOCKS5：SSH 反向动态转发，仅支持 TCP；目标域名由 SOCKS 端解析。
        \(socksCheck)
        """
        if includeHTTPAdapter {
            guard let httpCommands = httpCompatibilityCommands(remotePort: httpPort) else { return nil }
            text += "\n\n# Linux HTTP 兼容入口（Privoxy -> SOCKS5）\n\(httpCommands)"
        }
        if socksVerified != true {
            text += "\n# 注意：SOCKS5 入口当前尚未通过真实远端请求验证。"
        }
        if includeHTTPAdapter && httpVerified != true {
            text += "\n# 注意：HTTP 入口当前尚未通过 HTTP CONNECT 验证；请先查看 ProxyBridge 状态。"
        }
        return text
    }

    /// 按 PRD F07 生成 export 命令。协议必须来自实测（调用方保证），
    /// 未验证时调用方应提示用户，而不是阻止复制。
    /// 端口越界返回 nil（持久化脏数据防御，不崩溃）。
    static func exportCommands(remotePort: Int, protocol: ProxyProtocol) -> String? {
        guard (1...65_535).contains(remotePort) else { return nil }
        switch `protocol` {
        case .http:
            return """
            # ProxyBridge 生成：远端 HTTP 代理监听 127.0.0.1:\(remotePort)
            # 请先在「检查连接」中确认远端代理已验证可用
            export http_proxy=http://127.0.0.1:\(remotePort)
            export https_proxy=http://127.0.0.1:\(remotePort)
            curl -I --proxy http://127.0.0.1:\(remotePort) https://api.openai.com/v1/models
            """
        case .socks5:
            return """
            # ProxyBridge 生成：远端 SOCKS5 代理监听 127.0.0.1:\(remotePort)
            # 仅在实测 SOCKS5 可用时使用；DNS 经代理解析（socks5h）
            export ALL_PROXY=socks5h://127.0.0.1:\(remotePort)
            curl --socks5-hostname 127.0.0.1:\(remotePort) -I https://api.openai.com/v1/models
            """
        case .mixed:
            return """
            # ProxyBridge 生成：远端 Mixed 代理监听 127.0.0.1:\(remotePort)
            # HTTP 客户端使用 HTTP_PROXY；支持 SOCKS5 的客户端可单独使用 ALL_PROXY
            export http_proxy=http://127.0.0.1:\(remotePort)
            export https_proxy=http://127.0.0.1:\(remotePort)
            export ALL_PROXY=socks5h://127.0.0.1:\(remotePort)
            curl -I --proxy http://127.0.0.1:\(remotePort) https://api.openai.com/v1/models
            """
        }
    }

    /// 菜单栏「复制远端代理命令」入口：未验证时附提醒；端口非法返回 nil。
    static func clipboardText(remotePort: Int, protocol: ProxyProtocol, remoteVerified: Bool?) -> String? {
        guard let base = exportCommands(remotePort: remotePort, protocol: `protocol`) else { return nil }
        var out = base
        if remoteVerified != true {
            out += "\n# 注意：当前远端代理尚未验证（未验证 ≠ 可用），请先执行检查连接"
        }
        return out
    }
}
