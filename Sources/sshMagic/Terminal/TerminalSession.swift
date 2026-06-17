import Foundation

/// One open terminal tab. Identity is per-tab (not per-host) so you can have
/// several sessions to the same machine.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let host: Host

    /// Password to supply to ssh via the askpass helper. Held transiently for
    /// the lifetime of the session only; nil means "let ssh prompt in the
    /// terminal" (or use a key).
    let password: String?

    /// Unix socket for SSH connection multiplexing. The terminal's ssh opens
    /// this as the master; the SFTP file browser reuses it, so the file panel
    /// rides the terminal's already-authenticated connection instead of
    /// authenticating again (which would fail for interactively-typed passwords).
    let controlPath: String

    /// Live title — starts as the host label, updated from the shell's OSC title
    /// sequences (so it tracks `ssh`, then the remote shell's prompt title).
    @Published var title: String
    @Published var isConnected = true
    @Published var exitCode: Int32?

    /// Force `StrictHostKeyChecking=accept-new` even without a stored password.
    /// Set when reconnecting right after the user chose to overwrite a changed
    /// host key, so the freshly-presented key is recorded without a prompt.
    /// Write-once (set at init) so a reused session can't silently inherit it.
    let acceptNewHostKey: Bool

    /// Called when `ssh` exits with its own error code 255 (a connection/host-key
    /// failure, in either of SwiftTerm's raw/extracted status encodings) — not a
    /// normal logout or a remote command's own non-zero exit. AppState uses this
    /// to probe for a changed host key and offer to overwrite it.
    var onEarlyExit: (@MainActor (Int32?) -> Void)?

    /// Whether a SwiftTerm-reported exit code is ssh's own failure code 255 — the
    /// only case worth probing for a changed host key. SwiftTerm delivers the
    /// *raw* waitpid status on one code path (so 255 arrives as 0xFF00 = 65280)
    /// and the *extracted* code on another, so we match both. This excludes a
    /// remote shell's non-zero exit (e.g. `exit 1` → 0x0100 = 256), a clean
    /// logout (0), a signal death, and a nil IO error. Pure + nonisolated so it's
    /// unit-testable and documents the (otherwise undocumented) encoding contract.
    nonisolated static func isSSHFailure(exitCode: Int32?) -> Bool {
        // `code > 0` guards the arithmetic right-shift: a negative code (which
        // POSIX wait status never yields, but is theoretically deliverable)
        // would sign-extend so `(code >> 8) & 0xFF` spuriously hits 255.
        guard let code = exitCode, code > 0 else { return false }
        return code == 255 || (code >> 8) & 0xFF == 255
    }

    /// The file browser model. Cheap to create (it doesn't open an SFTP
    /// connection until the panel is first shown), so visibility is tracked in
    /// AppState while this just holds the per-session SFTP state.
    let filePanel: FilePanelModel

    /// Live remote-vitals monitor (CPU/RAM/net/disk), polled over the same
    /// multiplexed connection as the terminal and SFTP.
    let stats: RemoteStatsMonitor

    init(host: Host, password: String? = nil, acceptNewHostKey: Bool = false) {
        self.host = host
        self.password = password
        self.acceptNewHostKey = acceptNewHostKey
        self.title = host.displayName
        // Place the multiplex socket in the per-user temp dir (~/var/folders/.../T),
        // NOT world-readable /tmp, so other local users can't even enumerate it.
        // 16 hex chars (64 bits) is ample uniqueness while keeping the full path
        // well under the ~104-char AF_UNIX cap (the per-user dir is ~49 chars).
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        let control = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshmagic-\(token).sock").path
        self.controlPath = control
        self.filePanel = FilePanelModel(host: host, controlPath: control)
        self.stats = RemoteStatsMonitor(host: host, controlPath: control)
    }
}
