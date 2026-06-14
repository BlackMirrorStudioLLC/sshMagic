import AppKit
import Foundation

/// A remote file opened for editing: downloaded to a temp copy, opened in an
/// editor, and watched so saves are pushed back to the host.
@MainActor
final class EditSession {
    let remotePath: String
    let localURL: URL
    let displayName: String
    /// Last modification time we've already synced — a newer one means "save".
    var lastModified: Date
    var watcher: Task<Void, Never>?

    init(remotePath: String, localURL: URL, displayName: String) {
        self.remotePath = remotePath
        self.localURL = localURL
        self.displayName = displayName
        self.lastModified = EditSession.modified(localURL) ?? Date()
    }

    /// The temp copy's current modification date, if readable.
    static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        // Clean up the temp directory holding the copy.
        try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
    }
}

/// Opens a local file in the user's editor — Visual Studio Code when installed,
/// otherwise the system default text editor. Uses `/usr/bin/open`, the reliable
/// way to launch a GUI app for a file (the `code` shell-script CLI often fails
/// to launch when run from a sandboxless Process).
enum Editor {
    private static let vscodePaths = [
        "/Applications/Visual Studio Code.app",
        "\(NSHomeDirectory())/Applications/Visual Studio Code.app",
    ]

    static func open(_ url: URL) {
        if vscodePaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            run(["-a", "Visual Studio Code", url.path])
        } else {
            // `-t` forces the default *text* editor (e.g. TextEdit) rather than
            // whatever app claims the extension.
            run(["-t", url.path])
        }
    }

    private static func run(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        try? process.run()
    }
}
