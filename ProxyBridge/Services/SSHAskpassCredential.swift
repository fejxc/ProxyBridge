import Foundation

/// 密码模式的 SSH_ASKPASS 凭据装置（每次连接 / 一次性远端命令各一份，用后即毁）。
///
/// 机制：OpenSSH ≥ 8.4（macOS 14 自带 9.x）支持 `SSH_ASKPASS_REQUIRE=force`——
/// ssh 直接调用 helper 程序获取密码，无需 TTY、无提示词刮取、无 PTY 应答链路。
/// 目录结构（位于用户级临时目录，macOS 下该目录本身每用户隔离）：
/// - `askpass-helper.sh`（0700）：固定常量脚本，不含任何机密；
/// - `credential`（0600）：本次连接的密码，认证结果落定后立即删除。
///
/// 安全边界（替代 PTY 应答，如实记录）：
/// - 密码不经 argv、不经环境变量（helper 只收到文件路径，路径并非机密）；
/// - 密码短暂落盘（0600 文件 + 0700 目录，可见性与 PTY 方案同为「同用户进程」）；
/// - 已知折衷：进程在 destroy 之前崩溃可能残留文件——`sweepStaleDirectories()`
///   在每次创建前清理超过 1 小时的本 App 残留目录兜底（活跃连接的目录都是新的，
///   不会被并发误清）。
final class SSHAskpassCredential {
    /// helper 从该环境变量读取凭据文件路径（路径本身不是机密）。
    static let credentialFileEnvKey = "PROXYBRIDGE_ASKPASS_FILE"
    static let directoryPrefix = "proxybridge-askpass-"

    private let directory: URL
    private let helperURL: URL
    private let credentialURL: URL
    /// false = 文件系统准备失败，调用方按错误终态处理（不得使用）。
    private(set) var isValid = false

    /// helper 脚本：固定常量，绝不插入任何动态内容（密码只经凭据文件传递）。
    private static let helperScript = """
    #!/bin/sh
    # ProxyBridge SSH_ASKPASS helper. Recreated per connection; contains no
    # secret. Prints the credential file named by PROXYBRIDGE_ASKPASS_FILE;
    # OpenSSH strips the trailing newline (same semantics as the PTY answer).
    test -n "$PROXYBRIDGE_ASKPASS_FILE" && exec /bin/cat "$PROXYBRIDGE_ASKPASS_FILE"
    exit 1
    """

    init?(password: String) {
        Self.sweepStaleDirectories()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base.appendingPathComponent(
            Self.directoryPrefix + UUID().uuidString, isDirectory: true
        )
        let fileManager = FileManager.default
        // 独占创建：0700 目录；碰撞/不可写即失败，绝不复用已存在目录
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        self.directory = directory
        helperURL = directory.appendingPathComponent("askpass-helper.sh")
        credentialURL = directory.appendingPathComponent("credential")
        guard fileManager.createFile(
            atPath: helperURL.path,
            contents: Data(Self.helperScript.utf8),
            attributes: [.posixPermissions: 0o700]
        ), fileManager.createFile(
            atPath: credentialURL.path,
            contents: Data(password.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            try? fileManager.removeItem(at: directory)
            return nil
        }
        isValid = true
    }

    deinit {
        destroy()
    }

    /// ssh 进程环境需要追加的变量。
    var environmentAdditions: [String: String] {
        [
            "SSH_ASKPASS": helperURL.path,
            "SSH_ASKPASS_REQUIRE": "force",
            Self.credentialFileEnvKey: credentialURL.path,
        ]
    }

    /// 认证结果落定后调用：删除整个临时目录（幂等）。
    func destroy() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 清理历史残留（崩溃遗留）目录：仅动超过 1 小时的本前缀目录，
    /// 活跃连接的凭据目录都是新创建的，不会被误清。
    static func sweepStaleDirectories() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return
        }
        let staleDeadline = Date().addingTimeInterval(-3_600)
        for entry in entries where entry.lastPathComponent.hasPrefix(directoryPrefix) {
            if let attributes = try? fileManager.attributesOfItem(atPath: entry.path),
               let created = attributes[.creationDate] as? Date,
               created < staleDeadline {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
