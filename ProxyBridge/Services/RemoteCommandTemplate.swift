import Foundation

/// 生成「远端使用代理」的可复制命令（纯函数、无副作用）。
/// 端口只接受 Int；内容全部来自受控常量，不拼接用户自由文本。
enum RemoteCommandTemplate {

    /// 远端缺失、需要用户自行安装的依赖（App 不安装软件、不用 sudo）。
    /// HTTP 兼容入口已由 App 内实现（远端零依赖），curl 是唯一的远端探测依赖。
    enum RemoteTool: String, CaseIterable, Sendable {
        case curl

        var displayName: String { "curl" }
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
            text += "\n\n# Linux HTTP 兼容入口（由 ProxyBridge 在 Mac 侧实现，远端零依赖）\n\(httpCommands)"
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

    // MARK: - 接入助手（1.11.0）

    /// 常见 Linux 工具的接入模板：每套都是「使用 + 验证 + 撤销」三段。
    /// 只生成命令文本，执行由用户决定（App 不安装软件、不用 sudo、不修改服务器配置）；
    /// 持久化配置（git/npm/docker）必须附带撤销命令，断开隧道后用户能恢复直连。
    enum ToolPreset: String, CaseIterable, Sendable, Identifiable {
        case git
        case npm
        case pip
        case docker

        /// 菜单展示名（L10n 键，与词典一一对应）。
        var menuTitle: String {
            switch self {
            case .git: return "git（全局配置，含撤销）"
            case .npm: return "npm / pnpm（含撤销）"
            case .pip: return "pip / uv（当前 shell 生效）"
            case .docker: return "Docker 拉镜像（systemd，含撤销）"
            }
        }

        var id: String { rawValue }
    }

    /// 生成工具接入模板。统一要求 HTTP 形式代理入口（git/npm/docker 的代理配置
    /// 以 HTTP 代理为准；纯 SOCKS5 场景用户应改用环境变量模板）。
    /// 端口越界返回 nil；未验证时附提醒（与 clipboardText 同一语义）。
    static func toolPresetCommands(preset: ToolPreset, httpProxyPort: Int, remoteVerified: Bool?) -> String? {
        guard (1...65_535).contains(httpProxyPort) else { return nil }
        let proxy = "http://127.0.0.1:\(httpProxyPort)"
        var out: String
        switch preset {
        case .git:
            out = """
            # ProxyBridge 生成：git 走 HTTP 代理（写入 ~/.gitconfig，全局持久生效）
            # 断开隧道后务必执行撤销，否则 git 全部请求会打到失效端口
            git config --global http.proxy \(proxy)
            git config --global https.proxy \(proxy)
            # 验证（应正常返回 GitHub 仓库的 HEAD 引用）
            git ls-remote https://github.com/git/git.git HEAD
            # 撤销（恢复直连）
            git config --global --unset http.proxy
            git config --global --unset https.proxy
            """
        case .npm:
            out = """
            # ProxyBridge 生成：npm / pnpm 走 HTTP 代理（写入各包管理器配置，持久生效）
            # 断开隧道后务必执行撤销，否则安装全部失败
            npm config set proxy \(proxy)
            npm config set https-proxy \(proxy)
            # pnpm 不读 npm 的配置，需单独设置：
            pnpm config set proxy \(proxy)
            pnpm config set https-proxy \(proxy)
            # 验证（应返回 registry 响应时间）
            npm ping
            # 撤销（恢复直连）
            npm config delete proxy && npm config delete https-proxy
            pnpm config delete proxy && pnpm config delete https-proxy
            """
        case .pip:
            out = """
            # ProxyBridge 生成：pip / uv 走 HTTP 代理（仅当前 shell 生效，断开隧道后新开 shell 即恢复）
            export PIP_PROXY=\(proxy)
            # uv 与多数 Python 工具读标准代理环境变量：
            export http_proxy=\(proxy)
            export https_proxy=\(proxy)
            # 验证（应列出 requests 的可用版本）
            pip index versions requests || pip install --dry-run requests
            # 撤销（当前 shell 内恢复直连）
            unset PIP_PROXY http_proxy https_proxy
            """
        case .docker:
            out = """
            # ProxyBridge 生成：Docker daemon 拉镜像走 HTTP 代理
            # 需 sudo 并重启 docker，影响整台服务器（容器不中断，daemon 短暂不可用）
            # 方案 A（持久）：systemd 覆盖配置，断开隧道后需撤销，否则拉镜像全部失败
            sudo mkdir -p /etc/systemd/system/docker.service.d
            printf '[Service]\\nEnvironment="HTTP_PROXY=\(proxy)"\\nEnvironment="HTTPS_PROXY=\(proxy)"\\nEnvironment="NO_PROXY=localhost,127.0.0.1"\\n' | sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf
            sudo systemctl daemon-reload && sudo systemctl restart docker
            # 验证（应显示 HTTP Proxy 配置）
            docker info | grep -i proxy
            # 撤销（恢复直连）
            sudo rm /etc/systemd/system/docker.service.d/http-proxy.conf && sudo systemctl daemon-reload && sudo systemctl restart docker
            # 方案 B（临时，不重启 daemon）：仅对单个容器注入环境变量
            docker run -e http_proxy=\(proxy) -e https_proxy=\(proxy) <镜像>
            """
        }
        if remoteVerified != true {
            out += "\n# 注意：当前远端代理尚未验证（未验证 ≠ 可用），请先在 Mac 上执行检查连接"
        }
        return out
    }
}
