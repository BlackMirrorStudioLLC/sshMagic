import Foundation
import LocalAuthentication
import Security

/// Thin wrapper over the macOS Keychain for SSH passwords. Passwords are NEVER
/// written to `hosts.json` or passed on the ssh command line — they live only
/// here (encrypted at rest by the system) and are handed to ssh through an
/// `SSH_ASKPASS` helper at connect time.
///
/// When Touch ID is available the item is stored with a biometric access-control
/// policy: reading the secret then prompts for a fingerprint (not the "enter
/// keychain password" dialog), and that gate holds even across the ad-hoc
/// re-signing of dev builds. Without biometrics it falls back to a normal
/// when-unlocked item.
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
        // Replace any existing item so updates are idempotent (and so a legacy
        // non-biometric item is upgraded in place).
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        if BiometricAuth.isAvailable,
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryAny, nil)
        {
            // Reading this item will require a fingerprint.
            add[kSecAttrAccessControl as String] = access
        } else {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Whether a usable saved password exists, WITHOUT prompting. When Touch ID
    /// is available we only count biometric-protected items, so a legacy
    /// non-biometric item is ignored (the connect flow then re-prompts and
    /// re-saves it in the new format instead of triggering the keychain-password
    /// dialog).
    static func hasPassword(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            // Never show UI for an existence check.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecInteractionNotAllowed else {
            return false
        }
        guard BiometricAuth.isAvailable else { return true }
        // Biometric mode: require the item to carry an access-control policy.
        if let attrs = result as? [String: Any] {
            return attrs[kSecAttrAccessControl as String] != nil
        }
        // errSecInteractionNotAllowed with no attributes means it exists but is
        // auth-gated — i.e. biometric. Treat as usable.
        return status == errSecInteractionNotAllowed
    }

    /// Read the secret, prompting for Touch ID when the item is biometric. Runs
    /// off the main thread because the prompt blocks its thread. Returns nil if
    /// the item is missing or the user cancels/fails authentication.
    static func password(account: String, prompt: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = LAContext()
                context.localizedFallbackTitle = ""
                context.localizedReason = prompt
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecReturnData as String: true,
                    kSecUseAuthenticationContext as String: context,
                ]
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                if status == errSecSuccess, let data = item as? Data {
                    continuation.resume(returning: String(bytes: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
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
