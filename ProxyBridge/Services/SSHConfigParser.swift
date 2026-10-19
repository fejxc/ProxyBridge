import Foundation

/// `~/.ssh/config` 条目（P2 导入用）。
struct SSHConfigEntry: Identifiable, Equatable, Sendable {
    var id: String { alias }
    /// Host 行的别名（可能是空格分隔的模式，取第一个作为名字）。
    var alias: String
    var hostName: String?
    var port: Int?
    var user: String?
    var identityFile: String?
}

/// OpenSSH config 极简解析（纯函数）：支持 Host/HostName/Port/User/IdentityFile
/// 五个指令（大小写不敏感、`=` 或空格分隔、忽略注释与空行）。
/// Include 指令不展开；通配模式（* / ?）条目跳过（不能对应一台具体服务器）。
enum SSHConfigParser {

    static func parse(_ text: String) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var current: SSHConfigEntry?
        func flush() {
            if let entry = current { entries.append(entry) }
            current = nil
        }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // key value / key=value / key=value（去引号）
            let normalized = line.replacingOccurrences(of: "=", with: " ")
            let parts = normalized.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "host":
                flush()
                let alias = String(parts[1])
                // 通配/否定模式无法对应具体服务器，跳过
                guard !alias.contains("*"), !alias.contains("?"), !alias.hasPrefix("!") else { continue }
                current = SSHConfigEntry(alias: alias, hostName: nil, port: nil, user: nil, identityFile: nil)
            case "hostname":
                current?.hostName = value
            case "port":
                current?.port = Int(value)
            case "user":
                current?.user = value
            case "identityfile":
                current?.identityFile = value
            default:
                break // 其余指令（ProxyCommand 等）不导入
            }
        }
        flush()
        return entries
    }

    /// 读取并解析 ~/.ssh/config；文件不存在返回 nil（如实，不猜测）。
    static func loadDefaultConfig() -> [SSHConfigEntry]? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }
}
