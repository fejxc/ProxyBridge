import Foundation

/// profiles.json 的文档结构。`schemaVersion` 为将来迁移预留。
struct ProfilesDocument: Codable, Equatable {
    var schemaVersion: Int
    var profiles: [ServerProfile]
    var currentProfileId: UUID?

    static let currentSchemaVersion = 1

    static func empty() -> ProfilesDocument {
        ProfilesDocument(schemaVersion: currentSchemaVersion, profiles: [], currentProfileId: nil)
    }
}

enum ProfileRepositoryError: Error, Equatable {
    /// 文件存在但无法解码。调用方应把原文件挪走保底，再以空文档启动。
    case corrupted(underlying: String)
}

/// Profile 的 JSON 持久化。目录可注入以便测试（U18）。
final class ProfileRepository: @unchecked Sendable {
    private let directoryURL: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "dev.sunyun.ProxyBridge.profiles")

    init(directoryURL: URL? = nil) {
        let dir = directoryURL ?? Self.defaultDirectory()
        self.directoryURL = dir
        self.fileURL = dir.appendingPathComponent("profiles.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ProxyBridge", isDirectory: true)
    }

    var storageFileURL: URL { fileURL }

    /// 读取。文件不存在 → 空文档；解码失败 → 抛 corrupted（不静默丢弃用户数据）。
    func load() throws -> ProfilesDocument {
        try queue.sync {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return .empty()
            }
            do {
                let data = try Data(contentsOf: fileURL)
                let doc = try decoder.decode(ProfilesDocument.self, from: data)
                // 去重防御：id 重复时保留首次出现
                var seen = Set<UUID>()
                let deduped = doc.profiles.filter { seen.insert($0.id).inserted }
                var out = doc
                out.profiles = deduped
                if let cur = doc.currentProfileId, !seen.contains(cur) {
                    out.currentProfileId = deduped.first?.id
                }
                return out
            } catch let decodingError as DecodingError {
                throw ProfileRepositoryError.corrupted(underlying: String(describing: decodingError))
            } catch {
                throw ProfileRepositoryError.corrupted(underlying: error.localizedDescription)
            }
        }
    }

    /// 原子写入。目录不存在时自动创建。
    func save(_ document: ProfilesDocument) throws {
        try queue.sync {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: [.atomic])
        }
    }

    /// 将无法解码的文件改名保底（附时间戳），返回新路径。失败时抛底层错误。
    @discardableResult
    func quarantineCorruptFile() throws -> URL {
        try queue.sync {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let side = fileURL.deletingLastPathComponent()
                .appendingPathComponent("profiles.corrupt-\(stamp).json")
            try fileManager.moveItem(at: fileURL, to: side)
            return side
        }
    }
}
