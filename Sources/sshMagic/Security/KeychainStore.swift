import Foundation
import Security

/// Thin wrapper over the macOS Keychain for SSH passwords. Passwords are NEVER
/// written to `hosts.json` or passed on the ssh command line — they live only
/// here (encrypted at rest by the system) and are handed to ssh through an
/// `SSH_ASKPASS` helper at connect time.
///
/// Items are keyed by `account` (`username@host:port`) under a single service.
enum KeychainStore {
    private static let service = "com.blackmirrorstudio.sshmagic.ssh"

    /// The account string for a host+username pair.
    static func account(username: String, hostID: String) -> String {
        "\(username)@\(hostID)"
    }

    @discardableResult
    static func setPassword(_ password: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Replace any existing item so updates are idempotent.
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Returns the stored password, or nil if there's no item (a miss never
    /// prompts the user).
    static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let password = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return password
    }

    @discardableResult
    static func deletePassword(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
