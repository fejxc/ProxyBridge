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

/// OpenSSH config 极简解析（纯函数）：支持 Host/HostName/Port/User/IdentityFile/Include
/// 六个指令（大小写不敏感、`=` 或空格分隔、忽略注释与空行）。
/// Include 指令展开（1.10.0 起）：相对路径按 OpenSSH 语义相对 ~/.ssh、支持 glob 通配、
/// 深度上限防环引用；Include 出现在 Host 块内时当前条目先独立成段（被包含内容不并入
/// 该块的后续指令——此场景罕见，宁少导入不导错）。通配模式（* / ?）Host 条目跳过；
/// Match 块内条件化的指令不导入（其取值依赖连接参数，静默并入 Host 条目会导错）。
enum SSHConfigParser {

    /// Include 递归深度上限：OpenSSH 允许同一文件被重复包含，环引用是用户配置错误。
    static let maximumIncludeDepth = 5

    static func parse(_ text: String) -> [SSHConfigEntry] {
        parse(text, includeResolver: nil, depth: 0, visited: [])
    }

    /// 带 Include 展开的解析。`includeResolver` 收到 Include 值原文（可能是空格分隔的
    /// 多个路径、可含引号与通配符），返回 `(规范化键, 文件内容)`；nil = 该路径不可读
    /// （如实跳过，不猜测）。规范化键用于环引用与重复包含防护（同一文件的两种写法视为一个）。
    static func parse(
        _ text: String,
        includeResolver: ((String) -> (key: String, content: String)?)?,
        depth: Int = 0,
        visited: Set<String> = []
    ) -> [SSHConfigEntry] {
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
            case "include":
                // 被包含文件按 OpenSSH 语义如同内联展开；这里让当前条目先独立成段，
                // 再插入被包含文件的条目，随后父文件自身的 Host 继续追加。
                flush()
                if let resolver = includeResolver, depth < Self.maximumIncludeDepth {
                    for raw in includePaths(from: parts) {
                        guard !visited.contains(raw), let resolved = resolver(raw) else { continue }
                        entries += parse(
                            resolved.content,
                            includeResolver: resolver,
                            depth: depth + 1,
                            visited: visited.union([raw, resolved.key])
                        )
                    }
                }
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

    /// Include 值的路径列表：空格分隔的多个路径，每个可被成对引号包裹（含空格的路径）。
    static func includePaths(from parts: [String]) -> [String] {
        var paths: [String] = []
        var quoted: String?
        for part in parts {
            if let q = quoted {
                if part.hasSuffix("\"") || part.hasSuffix("'") {
                    paths.append(q + " " + String(part.dropLast()))
                    quoted = nil
                } else {
                    quoted = q + " " + part
                }
                continue
            }
            if (part.hasPrefix("\"") || part.hasPrefix("'")), part.count == 1 || !(part.hasSuffix("\"") || part.hasSuffix("'")) {
                quoted = String(part.dropFirst()) // 引号未闭合：累积到下一个以引号结尾的词
            } else if (part.hasPrefix("\"") && part.hasSuffix("\"") && part.count > 1)
                        || (part.hasPrefix("'") && part.hasSuffix("'") && part.count > 1) {
                paths.append(String(part.dropFirst().dropLast()))
            } else {
                paths.append(part)
            }
        }
        return paths
    }

    /// 读取并解析 ~/.ssh/config（展开 Include）；文件不存在返回 nil（如实，不猜测）。
    /// Include 相对路径按 OpenSSH 语义相对 ~/.ssh（主用户配置所在目录）。
    static func loadDefaultConfig() -> [SSHConfigEntry]? {
        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let url = sshDir.appendingPathComponent("config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, includeResolver: { Self.readIncludeFile($0, relativeTo: sshDir) })
    }

    /// Include 文件读取（生产 resolver）：`~` 展开、相对路径补全、glob 通配展开
    /// （`*` / `?`，按文件名排序保证确定性）；无匹配或不可读返回 nil。只读常规文件。
    /// 返回的 key 为规范化绝对路径（去重防护用），content 为文件内容（多文件按序拼接）。
    static func readIncludeFile(_ raw: String, relativeTo sshDir: URL) -> (key: String, content: String)? {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path == "~" { path = NSHomeDirectory() }
        else if path.hasPrefix("~/") { path = NSHomeDirectory() + path.dropFirst() }
        if !path.hasPrefix("/") { path = sshDir.appendingPathComponent(path).path }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let nsPath = canonical as NSString
        let directory = nsPath.deletingLastPathComponent
        let pattern = nsPath.lastPathComponent
        if pattern.contains("*") || pattern.contains("?") {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
            let regex = makeGlobRegex(pattern)
            let joined = names
                .filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
                .sorted()
                .compactMap { try? String(contentsOfFile: directory + "/" + $0, encoding: .utf8) }
            return joined.isEmpty ? nil : (canonical, joined.joined(separator: "\n"))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), !isDirectory.boolValue,
              let text = try? String(contentsOfFile: canonical, encoding: .utf8) else { return nil }
        return (canonical, text)
    }

    /// glob → 正则：`*` 匹配除 / 外的任意序列，`?` 匹配单个字符，其余字符按字面量转义。
    private static func makeGlobRegex(_ pattern: String) -> NSRegularExpression {
        var escaped = ""
        for ch in pattern {
            switch ch {
            case "*": escaped += "[^/]*"
            case "?": escaped += "[^/]"
            default: escaped += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return try! NSRegularExpression(pattern: "^\(escaped)$") // 模式来自用户自己的 ssh config，字符集已在调用方限定
    }
}
