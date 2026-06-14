import Foundation
import Security

/// Stores SSH passwords in the macOS Keychain. Passwords are NEVER written to
/// `hosts.json` or passed on the ssh command line — they live only here
/// (encrypted at rest) and are handed to ssh through an `SSH_ASKPASS` helper at
/// connect time.
///
/// Items are plain `kSecAttrAccessibleWhenUnlocked` generic passwords. We do NOT
/// use a biometric `kSecAttrAccessControl` policy: that requires the
/// `keychain-access-groups` entitlement (the write fails with `-34018`
/// otherwise), which an ad-hoc-signed build can't reliably get. Touch ID gating
/// is applied at the app level by `BiometricAuth` before the read instead.
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

    /// Whether a saved password exists — an existence check that never returns
    /// the secret, so it doesn't prompt.
    static func hasPassword(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The stored password, or nil if there's none (a miss never prompts).
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
            let password = String(bytes: data, encoding: .utf8)
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
