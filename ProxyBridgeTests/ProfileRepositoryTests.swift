import XCTest
@testable import ProxyBridge

/// U18：保存 / 重启 / 删除 profile 的 JSON round-trip 与损坏恢复。
final class ProfileRepositoryTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() {
        super.setUp()
        temp = TempDirectory.make()
    }

    override func tearDown() {
        temp.removeAll()
        super.tearDown()
    }

    private func makeRepo() -> ProfileRepository {
        ProfileRepository(directoryURL: temp.url)
    }

    private func sampleDocument() -> ProfilesDocument {
        var profile = ServerProfile(
            name: "实验室 GPU 服务器",
            host: "10.11.154.192",
            sshPort: 20064,
            username: "sunyun",
            authMode: .identityFile,
            identityFilePath: "~/.ssh/id_ed25519",
            remotePort: 7890,
            proxySelectionMode: .manual,
            manualEndpoint: LocalProxyEndpoint(
                host: "127.0.0.1", port: 7897, protocol: .socks5,
                origin: .manual, verifiedAt: Date(timeIntervalSince1970: 1_770_000_000)
            ),
            preferredProtocol: .socks5,
            reconnectEnabled: false,
            connectAtLaunch: true
        )
        profile.id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000001")!
        return ProfilesDocument(
            schemaVersion: ProfilesDocument.currentSchemaVersion,
            profiles: [profile],
            currentProfileId: profile.id
        )
    }

    // MARK: Round-trip

    func testMissingFileLoadsEmpty() throws {
        let doc = try makeRepo().load()
        XCTAssertTrue(doc.profiles.isEmpty)
        XCTAssertNil(doc.currentProfileId)
    }

    func testSaveLoadRoundTripPreservesAllFields() throws {
        let repo = makeRepo()
        let original = sampleDocument()
        try repo.save(original)

        let reloaded = try ProfileRepository(directoryURL: temp.url).load()
        XCTAssertEqual(reloaded.profiles, original.profiles, "全字段 round-trip 必须一致")
        XCTAssertEqual(reloaded.currentProfileId, original.currentProfileId)
        XCTAssertEqual(reloaded.schemaVersion, original.schemaVersion)

        let p = reloaded.profiles[0]
        XCTAssertEqual(p.manualEndpoint?.protocol, .socks5)
        XCTAssertEqual(p.manualEndpoint?.verifiedAt, Date(timeIntervalSince1970: 1_770_000_000))
        XCTAssertEqual(p.authMode, .identityFile)
        XCTAssertEqual(p.identityFilePath, "~/.ssh/id_ed25519")
        XCTAssertFalse(p.reconnectEnabled)
        XCTAssertTrue(p.connectAtLaunch)
    }

    func testDeleteProfilePersists() throws {
        let repo = makeRepo()
        var doc = sampleDocument()
        let extra = ServerProfile(name: "第二台", host: "192.168.1.100", sshPort: 22, username: "dev", remotePort: 7891)
        doc.profiles.append(extra)
        doc.currentProfileId = extra.id
        try repo.save(doc)

        doc.profiles.removeAll { $0.id == extra.id }
        doc.currentProfileId = doc.profiles.first?.id
        try repo.save(doc)

        let reloaded = try repo.load()
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertNotEqual(reloaded.currentProfileId, extra.id)
    }

    // MARK: 损坏恢复

    func testCorruptFileThrowsAndCanBeQuarantined() throws {
        let fileURL = temp.url.appendingPathComponent("profiles.json")
        try #"{"profiles": [broken json"#.data(using: .utf8)!.write(to: fileURL)

        let repo = makeRepo()
        XCTAssertThrowsError(try repo.load()) { error in
            guard case ProfileRepositoryError.corrupted = error else {
                return XCTFail("应抛出 .corrupted，实际 \(error)")
            }
        }

        let quarantined = try repo.quarantineCorruptFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path), "损坏文件应被改名保留")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        let doc = try repo.load()
        XCTAssertTrue(doc.profiles.isEmpty, "隔离后重新加载为空文档")
    }

    // MARK: 防御性去重

    func testDuplicateProfileIDsAreDeduplicatedOnLoad() throws {
        let fileURL = temp.url.appendingPathComponent("profiles.json")
        let id = "AAAAAAAA-BBBB-CCCC-DDDD-000000000001"
        let json = """
        {"schemaVersion":1,"currentProfileId":"\(id)","profiles":[
          {"id":"\(id)","name":"A","host":"a.example.com","sshPort":22,"username":"u","authMode":"agent","remotePort":7890,"proxySelectionMode":"automatic","preferredProtocol":"http","reconnectEnabled":true,"connectAtLaunch":false},
          {"id":"\(id)","name":"B","host":"b.example.com","sshPort":22,"username":"u","authMode":"agent","remotePort":7891,"proxySelectionMode":"automatic","preferredProtocol":"http","reconnectEnabled":true,"connectAtLaunch":false}
        ]}
        """
        try json.data(using: .utf8)!.write(to: fileURL)

        let doc = try makeRepo().load()
        XCTAssertEqual(doc.profiles.count, 1, "重复 id 去重后只保留首个")
        XCTAssertEqual(doc.profiles.first?.name, "A")
        XCTAssertEqual(doc.profiles.first?.connectionMode, .automatic, "旧配置应自动迁移到自动选择")
        XCTAssertEqual(doc.profiles.first?.remoteSocksPort, 17_890)
        XCTAssertEqual(doc.profiles.first?.remoteHTTPPort, 7_890)
        XCTAssertFalse(doc.profiles.first?.httpAdapterEnabled ?? true)
        XCTAssertEqual(doc.currentProfileId?.uuidString, id)
    }

    func testStaleCurrentProfileIdFallsBackToFirst() throws {
        let fileURL = temp.url.appendingPathComponent("profiles.json")
        let ghost = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let real = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000001")!
        let json = """
        {"schemaVersion":1,"currentProfileId":"\(ghost.uuidString)","profiles":[
          {"id":"\(real.uuidString)","name":"A","host":"a.example.com","sshPort":22,"username":"u","authMode":"agent","remotePort":7890,"proxySelectionMode":"automatic","preferredProtocol":"http","reconnectEnabled":true,"connectAtLaunch":false}
        ]}
        """
        try json.data(using: .utf8)!.write(to: fileURL)

        let doc = try makeRepo().load()
        XCTAssertEqual(doc.currentProfileId, real, "悬空的 currentProfileId 应回退到首个 profile")
    }

    // MARK: 存储 URL

    func testDefaultDirectoryIsInApplicationSupport() {
        let url = ProfileRepository.defaultDirectory()
        XCTAssertTrue(url.path.contains("Application Support"), "存储必须在用户 Application Support")
        XCTAssertTrue(url.path.contains("ProxyBridge"))
    }
}
