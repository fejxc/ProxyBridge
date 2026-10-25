import XCTest
@testable import ProxyBridge

/// SSH 参数构建与远端探测命令（U07/U08 + 注入面）。
final class SSHCommandBuilderTests: XCTestCase {

    private func profile(
        port: Int = 20064,
        authMode: AuthenticationMode = .agent,
        identityPath: String? = nil
    ) -> ServerProfile {
        ServerProfile(
            name: "实验室", host: "10.11.154.192", sshPort: port,
            username: "sunyun", authMode: authMode,
            identityFilePath: identityPath, remotePort: 7890
        )
    }

    private let endpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .systemHTTP)

    /// U08：严格参数（host key + loopback + BatchMode）。
    func testU08StrictArgumentsExactArray() {
        let args = SSHCommandBuilder.arguments(profile: profile(), localEndpoint: endpoint)
        XCTAssertEqual(args, [
            "-p", "20064",
            "-N", "-T",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StrictHostKeyChecking=yes",      // 安全红线：强制主机密钥校验
            "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes",
            "-R", "127.0.0.1:7890:127.0.0.1:7897",  // 安全红线：远端固定 loopback
            "sunyun@10.11.154.192",
        ])
    }

    func testAgentModeHasNoIdentityFileFlag() {
        let args = SSHCommandBuilder.arguments(profile: profile(), localEndpoint: endpoint)
        XCTAssertFalse(args.contains("-i"), "agent 模式不得默认加 -i（尊重用户 OpenSSH config）")
    }

    /// 密码模式：无 BatchMode（需交互应答）、强制密码路径、只允许一次尝试。
    func testPasswordModeArguments() {
        let args = SSHCommandBuilder.arguments(
            profile: profile(authMode: .password), localEndpoint: endpoint
        )
        XCTAssertFalse(args.contains("BatchMode=yes"), "密码模式不得启用 BatchMode（会直接失败）")
        XCTAssertTrue(args.contains("-o") && args.contains("PubkeyAuthentication=no"))
        XCTAssertTrue(args.contains("PreferredAuthentications=keyboard-interactive,password"))
        XCTAssertTrue(args.contains("NumberOfPasswordPrompts=1"), "错密码必须立即失败")
        XCTAssertTrue(args.contains("-o") && args.contains("StrictHostKeyChecking=yes"), "密码模式同样强制主机密钥校验")
        XCTAssertFalse(args.contains("-i"))
    }

    /// 密码模式的远端探测参数与隧道一致（无 BatchMode + 密码限制 + 无 -i）。
    func testRemoteProbePasswordModeArguments() {
        let args = RemoteProbeCommand.arguments(
            profile: profile(authMode: .password), remotePort: 7890,
            protocol: .http, urlString: "https://www.example.com/"
        )
        XCTAssertFalse(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("NumberOfPasswordPrompts=1"))
        XCTAssertFalse(args.contains("-i"))
    }

    /// U07：含空格的密钥路径逐字保真（单参数，无拆词/转义）。
    func testU07SpacedKeyPathPreservedVerbatim() {
        let spaced = "/Users/sunyun/My Keys/server key.pem"
        let args = SSHCommandBuilder.arguments(
            profile: profile(authMode: .identityFile, identityPath: spaced),
            localEndpoint: endpoint
        )
        guard let index = args.firstIndex(of: "-i") else {
            return XCTFail("identityFile 模式必须有 -i")
        }
        XCTAssertEqual(args[index + 1], spaced, "路径必须作为独立参数逐字保真")
        XCTAssertEqual(args.count - 1, index + 2, "-i 后是一个路径参数及目的地参数")
        XCTAssertEqual(args[index + 2], "sunyun@10.11.154.192")
    }

    func testLocalEndpointForwardedExactly() {
        let local = LocalProxyEndpoint(host: "localhost", port: 1080, protocol: .socks5, origin: .manual)
        let args = SSHCommandBuilder.arguments(profile: profile(), localEndpoint: local)
        guard let index = args.firstIndex(of: "-R") else {
            return XCTFail("必须有 -R")
        }
        XCTAssertEqual(args[index + 1], "127.0.0.1:7890:localhost:1080")
    }

    func testReverseDynamicUsesNativeRemoteSocksSyntaxWithoutLocalEndpoint() {
        let args = SSHCommandBuilder.arguments(profile: profile(), mode: .reverseDynamic)
        guard let index = args.firstIndex(of: "-R"), args.indices.contains(index + 1) else {
            return XCTFail("必须包含远端动态 SOCKS 转发参数")
        }
        XCTAssertEqual(args[index + 1], "127.0.0.1:17890")
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertFalse(args[index + 1].contains("127.0.0.1:7897"))
    }

    func testMixedProtocolUsesHTTPConnectForVerification() {
        let args = CurlProxyProbe.arguments(
            host: "127.0.0.1", port: 8890, protocol: .mixed,
            urlString: CurlProxyProbe.verificationURL, connectTimeout: 2, maxTime: 8
        )
        XCTAssertTrue(args.contains("--proxy"))
        XCTAssertTrue(args.contains("http://127.0.0.1:8890"))
    }

    func testRemoteManagementCommandsKeepHostKeyVerificationAndCommandAsOneArgument() {
        let args = SSHCommandBuilder.remoteCommandArguments(profile: profile(), command: "printf safe")
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertEqual(args.last, "printf safe")
        XCTAssertEqual(args[args.count - 2], "sunyun@10.11.154.192")
    }

    func testHTTPEntryForwardIsLoopbackOnlyAndAppendedAfterMainForward() {
        let entry = SSHCommandBuilder.httpEntryForwardArgument(profile: profile(), localPort: 51_234)
        XCTAssertEqual(entry, "127.0.0.1:7890:127.0.0.1:51234")
        // 动态模式附加入口转发：两条 -R 并存（远端均只绑定 127.0.0.1）
        let args = SSHCommandBuilder.arguments(profile: profile(), mode: .reverseDynamic, httpEntryLocalPort: 51_234)
        let forwards = args.indices.filter { args[$0] == "-R" }.map { args[$0 + 1] }
        XCTAssertEqual(forwards, ["127.0.0.1:17890", "127.0.0.1:7890:127.0.0.1:51234"])
        // 未启用入口时保持单条转发
        let plain = SSHCommandBuilder.arguments(profile: profile(), mode: .reverseDynamic)
        XCTAssertEqual(plain.indices.filter { plain[$0] == "-R" }.count, 1)
    }

    func testPortsAreNumericOnlyInPosition() {
        let args = SSHCommandBuilder.arguments(profile: profile(port: 22), localEndpoint: endpoint)
        // -p 的值参数必须是纯数字
        guard let p = args.firstIndex(of: "-p") else { return XCTFail("必须有 -p") }
        XCTAssertEqual(args[p + 1], "22")
        XCTAssertTrue(args[p + 1].allSatisfy(\.isNumber))
        // 端口只能出现在 -p 值与 -R 转发串中
        guard let r = args.firstIndex(of: "-R") else { return XCTFail("必须有 -R") }
        XCTAssertTrue(args[r + 1].contains(":7890:"))
    }

    // MARK: 远端探测命令（无用户自由文本）

    func testRemoteProbeArgumentsShape() {
        let args = RemoteProbeCommand.arguments(
            profile: profile(), remotePort: 7890,
            protocol: .http, urlString: "https://www.example.com/"
        )
        // agent 模式：10 元素，逐字精确断言
        XCTAssertEqual(args, [
            "-p", "20064",
            "-o", "StrictHostKeyChecking=yes",   // 远端探测同样强制主机密钥校验
            "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes",
            "sunyun@10.11.154.192",
            RemoteProbeCommand.script(remotePort: 7890, protocol: .http, urlString: "https://www.example.com/"),
        ])
        let script = args.last ?? ""
        XCTAssertTrue(script.contains("command -v curl"))
        XCTAssertTrue(script.contains("--proxy http://127.0.0.1:7890"))
        XCTAssertTrue(script.contains("https://www.example.com/"))
        XCTAssertTrue(script.contains(RemoteProbeCommand.noCurlMarker))
    }

    /// identityFile 模式：远端探测与隧道命令的 -i 行为必须一致（否则探测必然认证失败）。
    func testRemoteProbeIdentityFileMatchesTunnelCommand() {
        let spaced = "/Users/sunyun/My Keys/server key.pem"
        let idProfile = profile(authMode: .identityFile, identityPath: spaced)
        let probeArgs = RemoteProbeCommand.arguments(
            profile: idProfile, remotePort: 7890,
            protocol: .http, urlString: "https://www.example.com/"
        )
        let tunnelArgs = SSHCommandBuilder.arguments(profile: idProfile, localEndpoint: endpoint)
        // 两条命令都必须带 -i 且路径逐字一致
        for args in [probeArgs, tunnelArgs] {
            guard let i = args.firstIndex(of: "-i") else {
                return XCTFail("identityFile 模式下必须有 -i")
            }
            XCTAssertEqual(args[i + 1], spaced)
        }
    }

    func testRemoteProbeSOCKSUsesSocks5Hostname() {
        let script = RemoteProbeCommand.script(
            remotePort: 7891, protocol: .socks5, urlString: "https://www.example.com/"
        )
        XCTAssertTrue(script.contains("--socks5-hostname 127.0.0.1:7891"), "DNS 必须经代理解析")
        XCTAssertFalse(script.contains("--proxy http"))
    }

    /// 远端脚本是最终权威形态：全等断言（任何成分变化都必须显式更新此断言，
    /// 杜绝「审计白名单过宽放行注入成分」的假阴性）。
    func testRemoteProbeScriptIsExactConstant() {
        XCTAssertEqual(
            RemoteProbeCommand.script(
                remotePort: 7890, protocol: .http, urlString: "https://www.example.com/"
            ),
            "if ! command -v curl >/dev/null 2>&1; then echo \(RemoteProbeCommand.noCurlMarker); exit 0; fi; "
                + "exec curl --noproxy \"\" --proxy http://127.0.0.1:7890 "
                + "--connect-timeout 3 --max-time 8 --silent --show-error "
                + "--output /dev/null --write-out '%{http_code}' 'https://www.example.com/'"
        )
        XCTAssertEqual(
            RemoteProbeCommand.script(
                remotePort: 1080, protocol: .socks5, urlString: "https://www.example.com/"
            ),
            "if ! command -v curl >/dev/null 2>&1; then echo \(RemoteProbeCommand.noCurlMarker); exit 0; fi; "
                + "exec curl --noproxy \"\" --socks5-hostname 127.0.0.1:1080 "
                + "--connect-timeout 3 --max-time 8 --silent --show-error "
                + "--output /dev/null --write-out '%{http_code}' 'https://www.example.com/'"
        )
    }

    /// 带查询串（含 `&`）的业务目标必须整体留在 curl 参数里：
    /// 未加引号时远端 shell 会把 `&` 当后台操作符截断命令，探测恒失败。
    func testRemoteProbeScriptQuotesURLWithQueryParameters() {
        let script = RemoteProbeCommand.script(
            remotePort: 7890, protocol: .http,
            urlString: "https://www.example.com/v1/messages?foo=1&bar=2"
        )
        XCTAssertTrue(script.contains("'https://www.example.com/v1/messages?foo=1&bar=2'"))
        // 引号必须落在 URL 前后，shell 词法下 curl 只收到一个参数
        XCTAssertFalse(script.contains("bar=2 "))
    }
}
