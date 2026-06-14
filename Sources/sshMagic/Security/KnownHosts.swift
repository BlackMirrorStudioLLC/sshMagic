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
    /// ports). Runs on a background queue; `ssh-keygen` makes a `known_hosts.old`
    /// backup, so this is non-destructive to recover from. Failures are logged
    /// (not surfaced): if the key isn't removed, the only consequence is a
    /// host-key prompt on a future reconnect.
    ///
    /// `completion` runs on the main actor once all targets have been processed,
    /// reporting whether every `ssh-keygen -R` succeeded. The "overwrite changed
    /// key" flow uses it to reconnect only when the old key is actually gone — a
    /// failed removal (e.g. read-only `known_hosts`) would otherwise hit the
    /// stale key again and loop the prompt.
    static func forget(_ host: Host, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        var targets = [host.hostname]
        if host.port != 22 { targets.append("[\(host.hostname)]:\(host.port)") }

        DispatchQueue.global(qos: .utility).async {
            var allRemoved = true
            defer {
                if let completion {
                    Task { @MainActor in completion(allRemoved) }
                }
            }
            for target in targets {
                // Defence-in-depth against a hostile mDNS hostname that begins
                // with `-`. ssh-keygen's `-R` already consumes the next argv as
                // its operand regardless of a leading dash (so `-R -evil` removes
                // a host literally named `-evil`, it is NOT parsed as an option —
                // verified), so this is belt-and-suspenders. We deliberately do
                // NOT use `-R -- <target>`: ssh-keygen treats `--` as the operand
                // and rejects the call with "Too many arguments". A valid
                // hostname never starts with `-`, so simply skip one that does.
                guard !target.hasPrefix("-") else {
                    log.error("Refusing ssh-keygen -R for a leading-dash target: \(target, privacy: .public)")
                    allRemoved = false
                    continue
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                process.arguments = ["-R", target]
                // Discard stdout to /dev/null rather than an unread Pipe(): an
                // unread pipe would deadlock waitUntilExit() if the child ever
                // wrote more than the 64 KB buffer.
                process.standardOutput = FileHandle.nullDevice
                let errPipe = Pipe()
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    let reason = error.localizedDescription
                    log.error(
                        "ssh-keygen -R \(target, privacy: .public) failed to launch: \(reason, privacy: .public)")
                    allRemoved = false
                    continue
                }
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let code = process.terminationStatus
                    let detail = String(bytes: errData, encoding: .utf8) ?? ""
                    log.error(
                        "ssh-keygen -R \(target, privacy: .public) exited \(code): \(detail, privacy: .public)")
                    allRemoved = false
                }
            }
        }
    }
}
