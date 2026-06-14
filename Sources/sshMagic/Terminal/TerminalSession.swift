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

    /// The file browser model. Cheap to create (it doesn't open an SFTP
    /// connection until the panel is first shown), so visibility is tracked in
    /// AppState while this just holds the per-session SFTP state.
    let filePanel: FilePanelModel

    /// Live remote-vitals monitor (CPU/RAM/net/disk), polled over the same
    /// multiplexed connection as the terminal and SFTP.
    let stats: RemoteStatsMonitor

    init(host: Host, password: String? = nil) {
        self.host = host
        self.password = password
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
