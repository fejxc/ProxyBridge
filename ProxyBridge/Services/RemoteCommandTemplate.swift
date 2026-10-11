import Foundation

/// 生成「远端使用代理」的可复制命令（纯函数、无副作用）。
/// 端口只接受 Int；内容全部来自受控常量，不拼接用户自由文本。
enum RemoteCommandTemplate {

    /// 按 PRD F07 生成 export 命令。协议必须来自实测（调用方保证），
    /// 未验证时调用方应提示用户，而不是阻止复制。
    static func exportCommands(remotePort: Int, protocol: ProxyProtocol) -> String {
        precondition((1...65_535).contains(remotePort), "remotePort 必须在 1–65535")
        switch `protocol` {
        case .http:
            return """
            # ProxyBridge 生成：远端 HTTP 代理监听 127.0.0.1:\(remotePort)
            # 请先在「检查连接」中确认远端代理已验证可用
            export http_proxy=http://127.0.0.1:\(remotePort)
            export https_proxy=http://127.0.0.1:\(remotePort)
            curl -I https://www.example.com
            """
        case .socks5:
            return """
            # ProxyBridge 生成：远端 SOCKS5 代理监听 127.0.0.1:\(remotePort)
            # 仅在实测 SOCKS5 可用时使用；DNS 经代理解析（socks5h）
            export ALL_PROXY=socks5h://127.0.0.1:\(remotePort)
            curl -I https://www.example.com
            """
        }
    }

    /// 菜单栏「复制远端代理命令」入口：未验证时附提醒。
    static func clipboardText(remotePort: Int, protocol: ProxyProtocol, remoteVerified: Bool?) -> String {
        var out = exportCommands(remotePort: remotePort, protocol: `protocol`)
        if remoteVerified != true {
            out += "\n# 注意：当前远端代理尚未验证（未验证 ≠ 可用），请先执行检查连接"
        }
        return out
    }
}
