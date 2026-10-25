import Foundation
import CryptoKit

/// 一条远端主机公钥（ssh-keyscan 产出）。
struct HostKeyRecord: Equatable, Sendable {
    /// known_hosts 行格式的主机部分（22 端口为 `host`，非 22 为 `[host]:port`）。
    var hostField: String
    var keyType: String
    /// Base64 公钥内容（known_hosts 第三列）。
    var keyBlob: String
    /// `SHA256:…`（无 padding），与 OpenSSH 展示一致。
    var fingerprint: String

    /// 完整 known_hosts 行。
    var knownHostsLine: String { "\(hostField) \(keyType) \(keyBlob)" }
}

/// 主机指纹信任（TOFU）服务抽象：扫描 + 写入。
@MainActor
protocol HostKeyTrustProviding: AnyObject {
    /// ssh-keyscan 获取远端全部公钥（按算法去重，ed25519 优先）。
    func scan(host: String, port: Int) async -> [HostKeyRecord]
    /// 追加写入信任目标文件（生产环境解析 ssh 实际生效的 UserKnownHostsFile 首选文件，
    /// 解析失败回落 ~/.ssh/known_hosts；已存在相同行时跳过）。返回 false = 写入失败。
    func trust(_ records: [HostKeyRecord]) -> Bool
}

/// 真实实现：`/usr/bin/ssh-keyscan` + CryptoKit SHA256 指纹 + 原子追加。
/// 写入目标不能写死 ~/.ssh/known_hosts：用户 ssh config 若配置了 `UserKnownHostsFile`，
/// ssh 实际查用的文件与默认文件不同，把信任写进默认文件会让应用内 TOFU 静默失效
/// （主机密钥反复失败）。因此 trust 时先经 `ssh -G`（仅解析配置、不发起连接）取生效路径。
@MainActor
final class HostKeyTrustService: HostKeyTrustProviding {
    /// 回落/注入路径：显式注入（测试缝隙）时即为写入目标；否则为解析失败时的兜底。
    private let knownHostsURL: URL
    /// true = init 显式注入路径：跳过 ssh -G 解析，直接读写注入文件（单测不产生子进程）。
    private let isExplicitKnownHosts: Bool

    init(knownHostsURL: URL? = nil) {
        if let knownHostsURL {
            self.knownHostsURL = knownHostsURL
            self.isExplicitKnownHosts = true
        } else {
            let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
            if !FileManager.default.fileExists(atPath: sshDir.path) {
                try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
            }
            self.knownHostsURL = sshDir.appendingPathComponent("known_hosts")
            self.isExplicitKnownHosts = false
        }
    }

    func scan(host: String, port: Int) async -> [HostKeyRecord] {
        guard port > 0, port <= 65_535 else { return [] }
        // -T 限时；-t 限定现代算法（避免过时的 ssh-dss/CVE-2023-48795 前的弱协商噪音）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        process.arguments = ["-T", "5", "-t", "ed25519,ecdsa,rsa", "-p", String(port), "--", host]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            process.terminate()
            return []
        }
        guard let outputPipe = process.standardOutput as? Pipe else { return [] }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return Self.parseKeyScanOutput(text)
    }

    func trust(_ records: [HostKeyRecord]) -> Bool {
        guard !records.isEmpty else { return false }
        // 去重必须对照写入目标本身：目标文件里已有的行才算「已信任」
        let targetURL = trustTargetURL(for: records)
        let existing = (try? String(contentsOf: targetURL, encoding: .utf8)) ?? ""
        let existingLines = Set(existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let newLines = records.map(\.knownHostsLine).filter { !existingLines.contains($0) }
        guard !newLines.isEmpty else { return true } // 已全部信任（幂等）
        do {
            let append = (newLines.map { $0 + "\n" }.joined())
            if FileManager.default.fileExists(atPath: targetURL.path) {
                let handle = try FileHandle(forWritingTo: targetURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(append.utf8))
            } else {
                // 解析出的自定义路径可能整个目录都不存在：先补目录（权限与默认 ~/.ssh 一致）
                let dirURL = targetURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: dirURL.path) {
                    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirURL.path)
                }
                try Data(append.utf8).write(to: targetURL, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
            }
            return true
        } catch {
            return false
        }
    }

    /// 信任写入目标：显式注入优先（测试缝隙，恒不走解析）；否则按 ssh 生效配置解析；
    /// 解析任一环失败回落默认 ~/.ssh/known_hosts（与历史行为一致）。
    private func trustTargetURL(for records: [HostKeyRecord]) -> URL {
        if isExplicitKnownHosts { return knownHostsURL }
        // hostField 记录了 keyscan 时的主机与端口，反解后让 `ssh -G` 以与生产 ssh
        // 连接相同的参数视角（host + port）解析配置，Match 块才能命中同一条分支
        guard let first = records.first,
              let hostPort = Self.hostAndPort(fromHostField: first.hostField),
              let resolved = Self.resolveEffectiveKnownHostsFile(host: hostPort.host, port: hostPort.port) else {
            return knownHostsURL
        }
        return resolved
    }

    /// 解析 ssh 实际生效的 UserKnownHostsFile 首选文件；任一环失败返回 nil（由调用方回落）。
    /// 注意：`ssh -G` 以当前用户身份解析配置——known_hosts 路径极少落在按 user 区分的
    /// Match 块里，与生产 ssh 一致；极端配置（按远端用户命中的 `UserKnownHostsFile`）仍可能有偏差。
    private static func resolveEffectiveKnownHostsFile(host: String, port: Int) -> URL? {
        guard port > 0, port <= 65_535, !host.isEmpty else { return nil }
        guard let output = runSSHG(host: host, port: port),
              let raw = parseUserKnownHostsFile(fromGOutput: output) else { return nil }
        var path = raw
        if path.hasPrefix("~") {
            // ssh -G 通常已把 `~` 展开为绝对路径，这里只兜底裸 `~/` 写法；
            // `~user` 形式不展开（无法可靠定位他人家目录），交由回落处理
            guard path == "~" || path.hasPrefix("~/") else { return nil }
            path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
        }
        // 相对路径的语义依赖 ssh 进程的 cwd（各处启动方式不同），宁可回落默认文件也不写错位置
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// 运行 `ssh -G -p <port> -- <host>` 取生效配置全文。
    /// `-G` 只做配置解析、不发起网络连接，与生产 ssh 同读 ~/.ssh/config，
    /// 因此解析出的路径即连接时实际查用的文件。
    private static func runSSHG(host: String, port: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // `--` 防止以 `-` 开头的主机名被当作选项（Process 直传 argv，无 shell 注入面）
        process.arguments = ["-G", "-p", String(port), "--", host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // 有界等待（waitUntilExit 无超时，参考 UpdateInstaller.mount）：ssh -G 仅解析本地
        // 配置、通常毫秒级返回，2 秒仅为异常配置（如庞大的 Include）兜底；trust 是低频
        // 用户操作，协议签名限定同步返回，最坏阻塞主线程 2 秒可接受
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 纯函数（测试覆盖）

    /// 从 known_hosts 的主机字段反解 host 与端口（22 端口为 `host`，非 22 为 `[host]:port`），
    /// 供 `ssh -G` 复现生产 ssh 的连接参数视角；解析失败返回 nil（回落默认文件）。
    static func hostAndPort(fromHostField hostField: String) -> (host: String, port: Int)? {
        if hostField.hasPrefix("[") {
            guard let closeIdx = hostField.firstIndex(of: "]") else { return nil }
            let host = String(hostField[hostField.index(after: hostField.startIndex)..<closeIdx])
            let rest = hostField[hostField.index(after: closeIdx)...]
            guard !host.isEmpty, rest.hasPrefix(":"),
                  let port = Int(rest.dropFirst()), port > 0, port <= 65_535 else { return nil }
            return (host: host, port: port)
        }
        let host = hostField.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        return (host: host, port: 22)
    }

    /// 解析 `ssh -G` 输出中的 `userknownhostsfile` 行（键小写，值可空格分隔多个文件）。
    /// 只取第一个路径：ssh 自身添加新主机密钥时也写列表中的第一个文件，写入语义对齐。
    /// 取不到该行、或值为 `none`（ssh 明确不查用任何文件，无从对齐）时返回 nil。
    /// 已知局限：路径含空格时 OpenSSH 输出不加引号，无法与「多个文件」区分，可能取到片段。
    static func parseUserKnownHostsFile(fromGOutput text: String) -> String? {
        let key = "userknownhostsfile"
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key),
                  let sep = trimmed.dropFirst(key.count).first,
                  sep == " " || sep == "\t" else { continue } // 整词匹配，避免撞上其他键的前缀
            let value = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard let first = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { continue }
            let path = String(first)
            if path.lowercased() == "none" { return nil }
            return path
        }
        return nil
    }

    /// 解析 ssh-keyscan 输出：`[host]:port keytype base64…` 每行一条，
    /// 同算法取首条（重复扫描时 keyscan 可能输出多行同算法密钥）。
    static func parseKeyScanOutput(_ text: String) -> [HostKeyRecord] {
        var seen = Set<String>()
        var records: [HostKeyRecord] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let fingerprint = fingerprint(keyBlob: String(parts[2])) else { continue }
            let keyType = String(parts[1])
            guard !seen.contains(keyType) else { continue }
            seen.insert(keyType)
            records.append(HostKeyRecord(
                hostField: String(parts[0]),
                keyType: keyType,
                keyBlob: String(parts[2]),
                fingerprint: fingerprint
            ))
        }
        // 展示顺序：ed25519 → ecdsa → rsa → 其他
        let order = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"]
        return records.sorted { a, b in
            let ai = order.firstIndex(of: a.keyType) ?? order.count
            let bi = order.firstIndex(of: b.keyType) ?? order.count
            return ai < bi
        }
    }

    /// OpenSSH 格式指纹：`SHA256:<base64 无 padding>`；blob 非法返回 nil。
    static func fingerprint(keyBlob: String) -> String? {
        guard let blob = Data(base64Encoded: keyBlob), !blob.isEmpty else { return nil }
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:" + base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
