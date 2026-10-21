import XCTest
@testable import ProxyBridge

/// U06：端口 0/65536、非法 SSH hostname 必须拒绝保存/连接。
final class ProfileValidationTests: XCTestCase {

    private func makeProfile(
        name: String = "实验室服务器",
        host: String = "10.11.154.192",
        sshPort: Int = 20064,
        username: String = "sunyun",
        remotePort: Int = 17891
    ) -> ServerProfile {
        ServerProfile(
            name: name, host: host, sshPort: sshPort,
            username: username, remotePort: remotePort
        )
    }

    // MARK: 基线

    func testValidBaselineProfilePasses() {
        let v = ServerProfileRule.validate(makeProfile())
        XCTAssertTrue(v.isValid, "基线配置必须通过：\(v.errors)")
        XCTAssertTrue(v.warnings.isEmpty)
    }

    func testStaticAndHTTPEntryCannotBindSameRemotePort() {
        var profile = makeProfile(remotePort: 7890)
        XCTAssertFalse(ServerProfileRule.validate(profile).isValid)
        profile.connectionMode = .staticForward
        XCTAssertFalse(ServerProfileRule.validate(profile).isValid)
        profile.remotePort = 17891
        XCTAssertTrue(ServerProfileRule.validate(profile).isValid)
    }

    // MARK: 端口边界（U06）

    func testPortBoundaries() {
        XCTAssertFalse(ServerProfileRule.validate(makeProfile(sshPort: 0)).isValid, "SSH 端口 0 必须拒绝")
        XCTAssertFalse(ServerProfileRule.validate(makeProfile(sshPort: 65_536)).isValid, "SSH 端口 65536 必须拒绝")
        XCTAssertFalse(ServerProfileRule.validate(makeProfile(sshPort: -1)).isValid)
        XCTAssertTrue(ServerProfileRule.validate(makeProfile(sshPort: 1)).isValid)
        XCTAssertTrue(ServerProfileRule.validate(makeProfile(sshPort: 65_535)).isValid)

        XCTAssertFalse(ServerProfileRule.validate(makeProfile(remotePort: 0)).isValid, "远程端口 0 必须拒绝")
        XCTAssertFalse(ServerProfileRule.validate(makeProfile(remotePort: 65_536)).isValid, "远程端口 65536 必须拒绝")
        XCTAssertTrue(ServerProfileRule.validate(makeProfile(remotePort: 65_535)).isValid)
    }

    func testPrivilegedRemotePortProducesWarningButNotError() {
        let v = ServerProfileRule.validate(makeProfile(remotePort: 80))
        XCTAssertTrue(v.isValid, "<1024 端口允许保存（root 可绑定），但应有警告")
        XCTAssertTrue(v.warnings.contains { $0.contains("1024") })
    }

    func testV2PortsAndAdapterMustBeDistinct() {
        var profile = makeProfile()
        profile.remoteSocksPort = 0
        XCTAssertFalse(ServerProfileRule.validate(profile).isValid)

        profile.remoteSocksPort = 17_890
        profile.remoteHTTPPort = 17_890
        profile.httpAdapterEnabled = true
        XCTAssertFalse(ServerProfileRule.validate(profile).isValid)

        profile.remoteHTTPPort = 7_890
        XCTAssertTrue(ServerProfileRule.validate(profile).isValid)
    }

    // MARK: 主机白名单（U06：shell 控制字符）

    func testIllegalHostsAreRejected() {
        let badHosts = [
            "bad host",              // 空格
            "host;rm -rf /",         // 分号注入
            "$(whoami).example.com", // 命令替换
            "`id`.example.com",      // 反引号
            "host|nc attacker 4444", // 管道
            "hÖst.example.com",      // 非 ASCII
            "",                      // 空
            "example..com",          // 空标签
            "-leadinghyphen.example.com",
            "::1",                   // IPv6 字面量 MVP 不支持
            "fe80::1",
        ]
        for host in badHosts {
            let v = ServerProfileRule.validate(makeProfile(host: host))
            XCTAssertFalse(v.isValid, "主机「\(host)」必须被拒绝")
        }
    }

    func testLegalHostsAreAccepted() {
        let goodHosts = [
            "10.11.154.192",
            "192.168.1.100",
            "gpu-server.lab.example.com",
            "localhost",
            "host-1.example.com",
            "a.io",
            "xn--e1afmkfd.example.com", // punycode IDN 是合法主机名
        ]
        for host in goodHosts {
            let v = ServerProfileRule.validate(makeProfile(host: host))
            XCTAssertTrue(v.isValid, "主机「\(host)」应被接受：\(v.errors)")
        }
    }

    func testIPv4EdgeCases() {
        XCTAssertFalse(ServerProfileRule.isValidIPv4("256.1.1.1"))
        XCTAssertFalse(ServerProfileRule.isValidIPv4("1.2.3"))
        XCTAssertFalse(ServerProfileRule.isValidIPv4("01.2.3.4"))
        XCTAssertFalse(ServerProfileRule.isValidIPv4("1.2.3.4.5"))
        XCTAssertTrue(ServerProfileRule.isValidIPv4("0.0.0.0")) // 语法合法（是否可用是另一回事）
        XCTAssertTrue(ServerProfileRule.isValidIPv4("255.255.255.255"))
    }

    // MARK: 用户名（U06/U07：不得拼 shell）

    func testUsernameRules() {
        XCTAssertTrue(ServerProfileRule.validate(makeProfile(username: "sunyun")).isValid)
        XCTAssertTrue(ServerProfileRule.validate(makeProfile(username: "dev_01")).isValid)
        XCTAssertTrue(ServerProfileRule.validate(makeProfile(username: "a.b-c")).isValid)

        XCTAssertFalse(ServerProfileRule.validate(makeProfile(username: "")).isValid)
        XCTAssertFalse(ServerProfileRule.validate(makeProfile(username: "user;id")).isValid)
        XCTAssertFalse(ServerProfileRule.validate(makeProfile(username: "user name")).isValid)
        XCTAssertFalse(ServerProfileRule.validate(makeProfile(username: "user$(id)")).isValid)
        XCTAssertFalse(ServerProfileRule.validate(makeProfile(username: "-root")).isValid, "数字/符号开头拒绝")
        XCTAssertFalse(ServerProfileRule.validate(makeProfile(username: "1root")).isValid)
    }

    // MARK: 名称长度

    func testNameLength() {
        XCTAssertFalse(ServerProfileRule.validate(makeProfile(name: "")).isValid)
        XCTAssertFalse(ServerProfileRule.validate(makeProfile(name: String(repeating: "字", count: 41))).isValid)
        XCTAssertTrue(ServerProfileRule.validate(makeProfile(name: String(repeating: "字", count: 40))).isValid)
    }

    // MARK: 认证与手动代理

    func testIdentityFileModeRequiresPath() {
        var p = makeProfile()
        p.authMode = .identityFile
        p.identityFilePath = nil
        XCTAssertFalse(ServerProfileRule.validate(p).isValid, "identityFile 模式缺少路径必须报错")

        p.identityFilePath = "~/.ssh/id_ed25519"
        let v = ServerProfileRule.validate(p)
        XCTAssertTrue(v.isValid, "路径不存在只警告不报错：\(v.errors)")
        XCTAssertTrue(v.warnings.contains { $0.contains("不存在") })
    }

    func testManualModeRequiresValidEndpoint() {
        var p = makeProfile()
        p.connectionMode = .staticForward
        p.proxySelectionMode = .manual
        p.manualEndpoint = nil
        XCTAssertFalse(ServerProfileRule.validate(p).isValid, "手动模式缺端点必须报错")

        p.manualEndpoint = LocalProxyEndpoint(host: "0.0.0.0", port: 7897, protocol: .http, origin: .manual)
        XCTAssertFalse(ServerProfileRule.validate(p).isValid, "非回环地址必须报错")

        p.manualEndpoint = LocalProxyEndpoint(host: "127.0.0.1", port: 7897, protocol: .http, origin: .manual)
        XCTAssertTrue(ServerProfileRule.validate(p).isValid)
    }

    // MARK: 回环端点规则

    func testLoopbackEndpointRule() {
        XCTAssertTrue(LocalProxyEndpointRule.isValid(host: "127.0.0.1", port: 7897))
        XCTAssertTrue(LocalProxyEndpointRule.isValid(host: "LOCALHOST", port: 1))
        XCTAssertTrue(LocalProxyEndpointRule.isValid(host: "::1", port: 65_535))
        XCTAssertFalse(LocalProxyEndpointRule.isValid(host: "192.168.1.1", port: 7897))
        XCTAssertFalse(LocalProxyEndpointRule.isValid(host: "127.0.0.1", port: 0))
        XCTAssertFalse(LocalProxyEndpointRule.isValid(host: "127.0.0.1", port: 65_536))
        XCTAssertEqual(LocalProxyEndpointRule.validate(host: "10.0.0.1", port: 0).count, 2, "地址与端口各一条错误")
    }

    // MARK: U07 等价：含空格的密钥路径放行且保真（阶段 A 无 Process，校验/持久化等价覆盖）

    func testSpacedKeyPathPassesValidationAndRoundTrip() throws {
        var p = makeProfile()
        p.authMode = .identityFile
        let spaced = "/Users/sunyun/My Keys/server key.pem"
        p.identityFilePath = spaced
        XCTAssertTrue(ServerProfileRule.validate(p).isValid, "含空格路径是合法输入，不得拒绝")

        let temp = TempDirectory.make()
        defer { temp.removeAll() }
        let repo = ProfileRepository(directoryURL: temp.url)
        try repo.save(ProfilesDocument(schemaVersion: 1, profiles: [p], currentProfileId: p.id))
        let reloaded = try repo.load()
        XCTAssertEqual(reloaded.profiles.first?.identityFilePath, spaced, "路径必须逐字符保真（不拆词）")
    }

    // MARK: Tilde 展开

    func testTildeExpansion() {
        XCTAssertEqual(ServerProfileRule.expandTilde("/absolute/path"), "/absolute/path")
        XCTAssertEqual(ServerProfileRule.expandTilde("~"), NSHomeDirectory())
        XCTAssertEqual(
            ServerProfileRule.expandTilde("~/.ssh/id_ed25519"),
            NSHomeDirectory() + "/.ssh/id_ed25519"
        )
        XCTAssertNil(ServerProfileRule.expandTilde("~otheruser/key"), "跨用户 ~ 语法不展开")
    }

    // MARK: Remote bind 固定回环（安全红线）

    func testRemoteBindHostIsLoopbackOnly() {
        XCTAssertEqual(ServerProfile.remoteBindHost, "127.0.0.1", "MVP 远程绑定必须固定 loopback")
    }
}
