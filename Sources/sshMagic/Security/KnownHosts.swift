import Foundation
import OSLog

/// Removes a host's saved key from `~/.ssh/known_hosts` — the entry `ssh` adds
/// on first connect (via `StrictHostKeyChecking=accept-new`). Used when you
/// remove a saved connection so the box is fully forgotten; if you re-add it,
/// `ssh` will prompt/accept the key fresh.
enum KnownHosts {
    private static let log = Logger(
        subsystem: "com.blackmirrorstudio.sshmagic", category: "knownhosts")

    /// Run `ssh-keygen -R` for the host. Runs on a background queue; `ssh-keygen`
    /// makes a `known_hosts.old` backup, so this is non-destructive to recover
    /// from. Failures are logged (not surfaced): if the key isn't removed, the
    /// only consequence is a host-key prompt on a future reconnect.
    ///
    /// The forms tried are decided by `removalTargets(for:)` — see there for why
    /// a non-default-port host must NOT touch the bare `hostname` entry.
    ///
    /// `completion` runs on the main actor reporting whether the entry is
    /// actually GONE afterward (verified with `ssh-keygen -F`), not whether `-R`
    /// returned 0. `-R`'s exit code for a "host not found" target varies across
    /// OpenSSH versions, so verifying the end state is the only reliable signal.
    /// The "overwrite changed key" flow uses it to reconnect only when the old
    /// key is truly gone — a failed removal (e.g. read-only `known_hosts`) would
    /// otherwise hit the stale key again and loop the prompt.
    ///
    /// Gap (same as `HostKeyCheck.hasStoredKey`): both `-R` and the `-F`
    /// verification only touch the default `~/.ssh/known_hosts`. If the user
    /// redirects `UserKnownHostsFile` in ssh_config, `-R` removes nothing from
    /// the real file yet `-F` reports the key absent, so we'd report success and
    /// the reconnect would still fail on the stale key. The `acceptNewHostKey`
    /// guard prevents a prompt loop, so the worst case is one failed reconnect.
    static func forget(_ host: Host, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        let targets = removalTargets(for: host)

        DispatchQueue.global(qos: .utility).async {
            var removed = true
            defer {
                if let completion {
                    Task { @MainActor in completion(removed) }
                }
            }
            // A valid hostname never starts with `-`. We can't pass `-R -- <host>`
            // (ssh-keygen rejects `--` with "Too many arguments" — `-R` takes its
            // operand directly), so refuse a leading-dash name outright. Only the
            // bare form can trip this; the bracket form always starts with `[`.
            guard !targets.contains(where: { $0.hasPrefix("-") }) else {
                log.error(
                    "Refusing ssh-keygen -R for a leading-dash host: \(host.hostname, privacy: .public)")
                removed = false
                return
            }

            for target in targets {
                runKeygenRemove(target)
            }

            // Success = the entry no longer exists, regardless of `-R`'s exit
            // code. If any tried form still resolves, the removal didn't take.
            removed = targets.allSatisfy { !keyPresent($0) }
        }
    }

    /// The `ssh-keygen -R`/`-F` operands for a host. ssh records a non-default
    /// port only as `[host]:port` — the bare `hostname` line belongs to the
    /// port-22 endpoint, which may be a *different* saved host on the same
    /// machine. Touching the bare form for a non-22 host would silently delete
    /// that other endpoint's trust anchor, and the next port-22 connect (made
    /// with `StrictHostKeyChecking=accept-new`) would then trust whatever key
    /// the network presents. So: bare only when this host IS the port-22 one.
    /// On 22 the bracket form is also tried — some servers' IPv6 entries are
    /// recorded bracketed even on the default port, and a miss is harmless.
    static func removalTargets(for host: Host) -> [String] {
        let bracket = "[\(host.hostname)]:\(host.port)"
        return host.port == 22 ? [host.hostname, bracket] : [bracket]
    }

    /// Run `ssh-keygen -R <target>`, discarding output and logging any error.
    private static func runKeygenRemove(_ target: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-R", target]
        // Discard stdout to /dev/null rather than an unread Pipe(): an unread
        // pipe would deadlock waitUntilExit() if the child wrote past 64 KB.
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            let reason = error.localizedDescription
            log.error(
                "ssh-keygen -R \(target, privacy: .public) failed to launch: \(reason, privacy: .public)")
            return
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

    /// True when `known_hosts` still holds a key for `target` (`ssh-keygen -F`
    /// exits 0 on a match). Used to verify a removal actually took effect.
    private static func keyPresent(_ target: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-F", target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // Couldn't even check — assume the key may still be present so we
            // report removal *failure* rather than a false "removed" (which would
            // reconnect against a stale key).
            return true
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
