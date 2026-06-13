import Foundation
import LocalAuthentication

/// Touch ID availability check. The actual fingerprint prompt is driven by the
/// Keychain itself: `KeychainStore` stores the password with a biometric
/// access-control policy, so reading it triggers Touch ID. This only reports
/// whether biometrics exist — used to decide how to store the item.
enum BiometricAuth {
    /// Whether this Mac has Touch ID enrolled and usable right now.
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
}
