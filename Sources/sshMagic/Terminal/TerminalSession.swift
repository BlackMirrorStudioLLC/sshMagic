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

    /// Live title — starts as the host label, updated from the shell's OSC title
    /// sequences (so it tracks `ssh`, then the remote shell's prompt title).
    @Published var title: String
    @Published var isConnected = true
    @Published var exitCode: Int32?

    /// The file browser model. Cheap to create (it doesn't open an SFTP
    /// connection until the panel is first shown), so visibility is tracked in
    /// AppState while this just holds the per-session SFTP state.
    let filePanel: FilePanelModel

    init(host: Host, password: String? = nil) {
        self.host = host
        self.password = password
        self.title = host.displayName
        self.filePanel = FilePanelModel(host: host, password: password)
    }
}
