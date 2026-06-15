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
    /// We try BOTH the bare `hostname` and the bracketed `[hostname]:port` forms,
    /// always — ssh stores a non-default port (and IPv6 even on 22) only as
    /// `[host]:port`, and a plain host as the bare name; we don't know which up
    /// front.
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
        let bare = host.hostname
        let bracket = "[\(host.hostname)]:\(host.port)"

        DispatchQueue.global(qos: .utility).async {
            var removed = true
            defer {
                if let completion {
                    Task { @MainActor in completion(removed) }
                }
            }
            // A valid hostname never starts with `-`. We can't pass `-R -- <host>`
            // (ssh-keygen rejects `--` with "Too many arguments" — `-R` takes its
            // operand directly), so refuse a leading-dash name outright. The
            // bracket form starts with `[`, so it's always safe.
            guard !bare.hasPrefix("-") else {
                log.error("Refusing ssh-keygen -R for a leading-dash host: \(bare, privacy: .public)")
                removed = false
                return
            }

            for target in [bare, bracket] {
                runKeygenRemove(target)
            }

            // Success = the entry no longer exists, regardless of `-R`'s exit
            // code. If either form still resolves, the removal didn't take.
            removed = !keyPresent(bare) && !keyPresent(bracket)
        }
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
