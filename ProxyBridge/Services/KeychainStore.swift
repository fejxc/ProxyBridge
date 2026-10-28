import Foundation
import Security
import OSLog

/// SSH 密码的安全存储抽象。
/// 生产实现为 macOS Keychain（kSecClassGenericPassword，按 profile UUID 隔离）；
/// 测试/冒烟注入内存实现。密码绝不明文进入 profiles.json 或日志。
protocol PasswordStoring: AnyObject, Sendable {
    /// 返回是否写入成功（调用方可据此如实呈现；不抛错，避免把钥匙串状态
    /// 泄露进异常路径）。
    @discardableResult
    func save(_ password: String, for profileID: UUID) -> Bool
    func load(for profileID: UUID) -> String?
    func delete(for profileID: UUID)
    func exists(for profileID: UUID) -> Bool
}

/// 生产实现：Keychain。
/// 可访问性 `AfterFirstUnlock`：用户登录后本会话 App 均可读写（本应用为用户会话菜单栏应用）。
final class KeychainPasswordStore: PasswordStoring, @unchecked Sendable {
    private let service: String

    /// SSH 密码与上游代理密码用不同 service 隔离（同 account 互不可见）。
    init(service: String = "dev.sunyun.ProxyBridge.ssh-password") {
        self.service = service
    }

    private func baseQuery(for profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
    }

    @discardableResult
    func save(_ password: String, for profileID: UUID) -> Bool {
        var add = baseQuery(for: profileID)
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // upsert：先删后加，语义幂等
        SecItemDelete(baseQuery(for: profileID) as CFDictionary)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            // 绝不静默：写入失败必须留痕（不含密码内容）；返回值供调用方如实呈现，
            // 避免界面上「已记住」与钥匙串实际状态不一致
            Logger(subsystem: "dev.sunyun.ProxyBridge", category: "keychain")
                .error("钥匙串写入失败（status \(status)）：记住密码未生效")
        }
        return status == errSecSuccess
    }

    func load(for profileID: UUID) -> String? {
        var query = baseQuery(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(for profileID: UUID) {
        SecItemDelete(baseQuery(for: profileID) as CFDictionary)
    }

    func exists(for profileID: UUID) -> Bool {
        load(for: profileID) != nil
    }
}
