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
    /// 追加写入 ~/.ssh/known_hosts（已存在相同行时跳过）。返回 false = 写入失败。
    func trust(_ records: [HostKeyRecord]) -> Bool
}

/// 真实实现：`/usr/bin/ssh-keyscan` + CryptoKit SHA256 指纹 + 原子追加。
@MainActor
final class HostKeyTrustService: HostKeyTrustProviding {
    private let knownHostsURL: URL

    init(knownHostsURL: URL? = nil) {
        if let knownHostsURL {
            self.knownHostsURL = knownHostsURL
        } else {
            let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
            if !FileManager.default.fileExists(atPath: sshDir.path) {
                try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
            }
            self.knownHostsURL = sshDir.appendingPathComponent("known_hosts")
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
        let existing = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
        let existingLines = Set(existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let newLines = records.map(\.knownHostsLine).filter { !existingLines.contains($0) }
        guard !newLines.isEmpty else { return true } // 已全部信任（幂等）
        do {
            let append = (newLines.map { $0 + "\n" }.joined())
            if FileManager.default.fileExists(atPath: knownHostsURL.path) {
                let handle = try FileHandle(forWritingTo: knownHostsURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(append.utf8))
            } else {
                try Data(append.utf8).write(to: knownHostsURL, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsURL.path)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - 纯函数（测试覆盖）

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
