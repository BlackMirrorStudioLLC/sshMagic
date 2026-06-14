import Foundation
import LocalAuthentication

/// App-level Touch ID gate. We authorize *use* of a Keychain-stored SSH password
/// with a fingerprint before reading it; on failure the caller falls back to
/// typing the password. (Keychain-level biometric protection would need the
/// `keychain-access-groups` entitlement, which an ad-hoc build can't get, so the
/// gate lives here instead.)
enum BiometricAuth {
    /// Whether this Mac has Touch ID enrolled and usable right now.
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Prompt for Touch ID. Returns true only on a successful fingerprint match;
    /// any failure, cancel, or unavailability returns false so the caller can
    /// fall back to manual entry.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        // Hide the "Enter Password" (device passcode) fallback — our fallback is
        // typing the SSH password, not the Mac login password.
        context.localizedFallbackTitle = ""

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        else { return false }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics, localizedReason: reason
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
