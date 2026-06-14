import Foundation

/// Removes a host's saved key from `~/.ssh/known_hosts` — the entry `ssh` adds
/// on first connect (via `StrictHostKeyChecking=accept-new`). Used when you
/// remove a saved connection so the box is fully forgotten; if you re-add it,
/// `ssh` will prompt/accept the key fresh.
enum KnownHosts {
    /// Run `ssh-keygen -R` for the host (and its `[host]:port` form on non-22
    /// ports). Fire-and-forget on a background queue; `ssh-keygen` makes a
    /// `known_hosts.old` backup, so this is non-destructive to recover from.
    static func forget(_ host: Host) {
        var targets = [host.hostname]
        if host.port != 22 { targets.append("[\(host.hostname)]:\(host.port)") }

        DispatchQueue.global(qos: .utility).async {
            for target in targets {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                process.arguments = ["-R", target]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try? process.run()
                process.waitUntilExit()
            }
        }
    }
}
