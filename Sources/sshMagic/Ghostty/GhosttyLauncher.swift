import AppKit
import Foundation

/// Opens an SSH session in Ghostty instead of an embedded tab — the "give me the
/// real, GPU-accelerated thing" escape hatch.
///
/// Ghostty's macOS bundle accepts `-e <command>` to run a one-off command in a
/// fresh window. We locate the CLI inside the app bundle so this works whether or
/// not `ghostty` is on the user's PATH.
enum GhosttyLauncher {
    /// Candidate locations for the Ghostty CLI, in priority order.
    private static let candidatePaths = [
        "/Applications/Ghostty.app/Contents/MacOS/ghostty",
        "\(NSHomeDirectory())/Applications/Ghostty.app/Contents/MacOS/ghostty",
    ]

    static var isAvailable: Bool { resolvedBinary() != nil }

    /// Launch `ssh <host>` in a new Ghostty window. Returns false if Ghostty
    /// isn't installed where we can find it.
    @discardableResult
    static func open(_ host: Host) -> Bool {
        guard let binary = resolvedBinary() else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // `-e` tells Ghostty to run this argv instead of a login shell.
        process.arguments = ["-e", "/usr/bin/ssh"] + host.sshArguments

        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func resolvedBinary() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
