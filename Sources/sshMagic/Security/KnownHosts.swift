import Foundation
import OSLog

/// Removes a host's saved key from `~/.ssh/known_hosts` — the entry `ssh` adds
/// on first connect (via `StrictHostKeyChecking=accept-new`). Used when you
/// remove a saved connection so the box is fully forgotten; if you re-add it,
/// `ssh` will prompt/accept the key fresh.
enum KnownHosts {
    private static let log = Logger(
        subsystem: "com.blackmirrorstudio.sshmagic", category: "knownhosts")

    /// Run `ssh-keygen -R` for the host (and its `[host]:port` form on non-22
    /// ports). Fire-and-forget on a background queue; `ssh-keygen` makes a
    /// `known_hosts.old` backup, so this is non-destructive to recover from.
    /// Failures are logged (not surfaced): if the key isn't removed, the only
    /// consequence is a host-key prompt on a future reconnect, so logging is
    /// enough to diagnose without blocking the remove flow.
    static func forget(_ host: Host) {
        var targets = [host.hostname]
        if host.port != 22 { targets.append("[\(host.hostname)]:\(host.port)") }

        DispatchQueue.global(qos: .utility).async {
            for target in targets {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                process.arguments = ["-R", target]
                process.standardOutput = Pipe()
                let errPipe = Pipe()
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    let reason = error.localizedDescription
                    log.error(
                        "ssh-keygen -R \(target, privacy: .public) failed to launch: \(reason, privacy: .public)")
                    continue
                }
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let code = process.terminationStatus
                    let detail = String(bytes: errData, encoding: .utf8) ?? ""
                    log.error(
                        "ssh-keygen -R \(target, privacy: .public) exited \(code): \(detail, privacy: .public)")
                }
            }
        }
    }
}
