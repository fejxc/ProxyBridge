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
/// Include 指令不展开；通配模式（* / ?）条目跳过（不能对应一台具体服务器）；
/// Match 块内条件化的指令不导入（其取值依赖连接参数，静默并入 Host 条目会导错）。
enum SSHConfigParser {

    static func parse(_ text: String) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var current: SSHConfigEntry?
        var inMatchBlock = false
        func flush() {
            if let entry = current { entries.append(entry) }
            current = nil
        }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // key 与值分离：在第一个空白或 `=` 处切（`=` 只作分隔符，
            // 绝不能整行替换——值内出现 `=`（如 IdentityFile=/a=b）会被破坏）
            guard let keyEnd = line.firstIndex(where: { $0 == "=" || $0 == " " || $0 == "\t" }) else { continue }
            let key = String(line[..<keyEnd]).lowercased()
            var rest = line[line.index(after: keyEnd)...]
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            if rest.hasPrefix("=") { rest = rest.dropFirst() }
            let parts = rest.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard !parts.isEmpty else { continue }
            let value = parts.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "host":
                flush()
                inMatchBlock = false
                // Host 行可含多个模式（如 Host web db），取第一个；引号包裹的别名整体去引号
                let alias = value.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? value
                // 通配/否定模式无法对应具体服务器，跳过
                guard !alias.contains("*"), !alias.contains("?"), !alias.hasPrefix("!") else { continue }
                current = SSHConfigEntry(alias: alias, hostName: nil, port: nil, user: nil, identityFile: nil)
            case "match":
                flush()
                inMatchBlock = true
            case "hostname":
                if !inMatchBlock { current?.hostName = value }
            case "port":
                if !inMatchBlock { current?.port = Int(value) }
            case "user":
                if !inMatchBlock { current?.user = value }
            case "identityfile":
                if !inMatchBlock { current?.identityFile = value }
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
