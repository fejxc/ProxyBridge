import Foundation

/// SSH 命令构建（纯函数，02-TECHNICAL-DESIGN §5）。
///
/// 安全不变量（均有测试钉死）：
/// - 参数数组直传给 `/usr/bin/ssh`，全程不经 shell；
/// - `StrictHostKeyChecking=yes` 强制（红线：绝不允许 no / accept-new）；
/// - 远端绑定固定 `127.0.0.1`（红线：绝不 0.0.0.0）；
/// - `-i` 仅在 identityFile 模式且路径非空时追加，路径逐字保真（含空格）；
/// - 端口必须为 Int（数字注入面为零）。
enum SSHCommandBuilder {

    static let executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

    /// 隧道保活用的 ssh 参数数组（不含可执行文件路径）。
    static func arguments(profile: ServerProfile, localEndpoint: LocalProxyEndpoint) -> [String] {
        precondition(LocalProxyEndpointRule.isValid(host: localEndpoint.host, port: localEndpoint.port),
                     "本地端点必须是合法回环端点")
        precondition((1...65_535).contains(profile.remotePort), "remotePort 必须在 1–65535")
        return tunnelArguments(
            profile: profile,
            forwardSpecifications: [forwardArgument(profile: profile, localEndpoint: localEndpoint)]
        )
    }

    /// Build either a legacy static reverse forward or OpenSSH native reverse
    /// dynamic SOCKS forward, plus an optional HTTP entry forward. The dynamic
    /// form intentionally has no local host/port suffix: `-R 127.0.0.1:17890`
    /// is the SOCKS listener itself.
    static func arguments(
        profile: ServerProfile,
        mode: ConnectionMode,
        localEndpoint: LocalProxyEndpoint? = nil,
        httpEntryLocalPort: UInt16? = nil
    ) -> [String] {
        var forwards: [String]
        switch mode {
        case .staticForward:
            guard let localEndpoint else { preconditionFailure("静态转发必须提供本地代理端点") }
            forwards = [forwardArgument(profile: profile, localEndpoint: localEndpoint)]
        case .reverseDynamic:
            precondition((1...65_535).contains(profile.remoteSocksPort), "remoteSocksPort 必须在 1–65535")
            forwards = [dynamicForwardArgument(profile: profile)]
        case .automatic:
            preconditionFailure("automatic 必须先解析为实际连接模式")
        }
        if let httpEntryLocalPort {
            forwards.append(httpEntryForwardArgument(profile: profile, localPort: httpEntryLocalPort))
        }
        return tunnelArguments(profile: profile, forwardSpecifications: forwards)
    }

    private static func tunnelArguments(profile: ServerProfile, forwardSpecifications: [String]) -> [String] {
        precondition((1...65_535).contains(profile.sshPort), "sshPort 必须在 1–65535")

        var args: [String] = [
            "-p", String(profile.sshPort),
            "-N", "-T",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes",         // 转发建立失败立即退出（可检测）
            "-o", "StrictHostKeyChecking=yes",        // 主机密钥强制校验（安全红线）
            "-o", "ConnectTimeout=10",
        ]
        if profile.authMode == .password {
            // 密码模式：密码经 SSH_ASKPASS helper（force 模式，无 TTY）交付，
            // 见 SSHAskpassCredential——不经 argv、不经环境变量、不经日志；
            // 禁用公钥路径、只允许一次密码尝试（错密码立即失败，行为可预期）
            args += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "NumberOfPasswordPrompts=1",
            ]
        } else {
            args += ["-o", "BatchMode=yes"]           // 非密码模式禁止任何交互提示
        }
        args += ["-R", forwardSpecifications.first!]
        for extra in forwardSpecifications.dropFirst() {
            args += ["-R", extra] // HTTP 兼容入口等附加转发（远端同样只绑定 127.0.0.1）
        }
        if profile.authMode == .identityFile,
           let path = profile.identityFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            args += ["-i", path] // 路径逐字保真（U07：含空格也不拆词、不转义）
        }
        args.append(destination(profile: profile))
        return args
    }

    /// `-R` 转发参数：远端绑定固定 loopback。
    static func forwardArgument(profile: ServerProfile, localEndpoint: LocalProxyEndpoint) -> String {
        "\(ServerProfile.remoteBindHost):\(profile.remotePort):\(localEndpoint.host):\(localEndpoint.port)"
    }

    /// OpenSSH dynamic reverse-forward syntax, with no `host:hostport` suffix.
    static func dynamicForwardArgument(profile: ServerProfile) -> String {
        "\(ServerProfile.remoteBindHost):\(profile.remoteSocksPort)"
    }

    /// HTTP 兼容入口转发：远端 `127.0.0.1:<remoteHTTPPort>` → Mac 本地入口监听。
    /// 入口由 App 内 HTTPEntryRelay 实现（远端零依赖，无需 Privoxy）。
    static func httpEntryForwardArgument(profile: ServerProfile, localPort: UInt16) -> String {
        "\(ServerProfile.remoteBindHost):\(profile.remoteHTTPPort):\(ServerProfile.remoteBindHost):\(localPort)"
    }

    /// One-shot remote command arguments. The remote command is one SSH argv
    /// element; callers must construct it from fixed text and validated values.
    static func remoteCommandArguments(profile: ServerProfile, command: String) -> [String] {
        precondition((1...65_535).contains(profile.sshPort), "sshPort 必须在 1–65535")
        var args = ["-p", String(profile.sshPort), "-T", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10"]
        if profile.authMode == .password {
            args += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "NumberOfPasswordPrompts=1",
            ]
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        if profile.authMode == .identityFile,
           let path = profile.identityFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            args += ["-i", path]
        }
        args.append(destination(profile: profile))
        args.append(command)
        return args
    }

    /// `user@host` 目的地。host/user 已在模型校验层通过白名单，但仍组装为单个参数。
    static func destination(profile: ServerProfile) -> String {
        "\(profile.username)@\(profile.host)"
    }
}

/// 远端一次性验证命令（02-TECHNICAL-DESIGN §7）。
///
/// 远端脚本只能由受控常量 + 经校验的数字端口 + 白名单 URL 组成，
/// 绝不插入用户自由文本；`ssh` 会在远端经登录 shell 执行，因此这里
/// 的每个字符都必须来自代码常量（有测试断言脚本成分）。
enum RemoteProbeCommand {

    /// 不可用时输出的标记（识别「远端没有 curl」→ unknown 而非失败）。
    static let noCurlMarker = "__PROXYBRIDGE_NO_CURL__"

    static func arguments(
        profile: ServerProfile,
        remotePort: Int,
        protocol: ProxyProtocol,
        urlString: String
    ) -> [String] {
        precondition((1...65_535).contains(profile.sshPort), "sshPort 必须在 1–65535")
        precondition((1...65_535).contains(remotePort), "remotePort 必须在 1–65535")
        // 固定白名单，或经 ServerProfile.sanitizedProbeTarget 清洗的用户业务目标
        precondition(CurlProxyProbe.urlWhitelist.contains(urlString)
                     || ServerProfile.sanitizedProbeTarget(urlString) != nil,
                     "验证 URL 必须来自白名单或通过清洗")
        var args = [
            "-p", String(profile.sshPort),
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10",
        ]
        if profile.authMode == .password {
            args += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "NumberOfPasswordPrompts=1",
            ]
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        // 与隧道命令同条件复用身份（§7：探测复用 profile 的 host/port/identity 参数）
        if profile.authMode == .identityFile,
           let path = profile.identityFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            args += ["-i", path]
        }
        args.append(SSHCommandBuilder.destination(profile: profile))
        args.append(script(remotePort: remotePort, protocol: `protocol`, urlString: urlString))
        return args
    }

    /// 远端脚本：curl 缺失输出标记；否则经远端 127.0.0.1:<port> 实测一次 HTTPS 请求。
    static func script(remotePort: Int, protocol: ProxyProtocol, urlString: String) -> String {
        let proxyArg: String
        switch `protocol` {
        case .http: proxyArg = "--proxy http://127.0.0.1:\(remotePort)"
        case .socks5: proxyArg = "--socks5-hostname 127.0.0.1:\(remotePort)" // DNS 经代理解析
        case .mixed: proxyArg = "--proxy http://127.0.0.1:\(remotePort)" // HTTP CONNECT 验证 Mixed 的 HTTP 能力
        }
        return "if ! command -v curl >/dev/null 2>&1; then echo \(noCurlMarker); exit 0; fi; "
            + "exec curl --noproxy \"\" \(proxyArg) "
            + "--connect-timeout 3 --max-time 8 --silent --show-error "
            + "--output /dev/null --write-out '%{http_code}' \(urlString)"
    }
}
