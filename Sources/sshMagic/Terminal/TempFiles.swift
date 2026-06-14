import Foundation

/// Cleans up the app's temporary artifacts. Everything sshMagic writes to the
/// per-user temp dir is named `sshmagic-…`: edit/download staging directories
/// (which can briefly hold sensitive remote files — SSH keys, `.env`, configs),
/// the `SSH_ASKPASS` password directories, and the SSH multiplexing sockets.
///
/// These are removed on normal teardown, but a crash or force-quit skips that.
/// `sweepStaleArtifacts()` runs once at launch — before any new session creates
/// its own — so leftovers from a previous run never linger on disk.
enum TempFiles {
    private static let prefix = "sshmagic-"

    static func sweepStaleArtifacts() {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: fm.temporaryDirectory, includingPropertiesForKeys: nil)
        else { return }
        for url in entries where url.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: url)
        }
    }
}
