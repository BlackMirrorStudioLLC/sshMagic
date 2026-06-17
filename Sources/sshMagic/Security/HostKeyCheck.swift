import Foundation

/// Classifies *why* an `ssh` connection failed when we suspect a host-key
/// problem. Specifically detects the "REMOTE HOST IDENTIFICATION HAS CHANGED!"
/// case — where a key we previously trusted no longer matches — so the app can
/// turn that scary wall of text into an actionable "overwrite the saved key?"
/// prompt instead of leaving the user stuck.
enum HostKeyCheck {
    struct ChangedKey: Equatable {
        /// The fingerprint of the key the server now presents (parsed from the
        /// warning), shown to the user so they can verify it out-of-band.
        let newFingerprint: String?
    }

    /// Run a non-interactive probe whose only purpose is the host-key check — it
    /// never authenticates (`BatchMode=yes`) and never writes `known_hosts`
    /// (`StrictHostKeyChecking=yes`). The host-key handshake happens *before*
    /// auth, so a changed key still produces the warning we look for. Returns
    /// nil when the key is fine/unknown or the host is simply unreachable.
    static func detectChangedKey(for host: Host) async -> ChangedKey? {
        // If we have no stored key for this host, nothing could have *changed* —
        // skip the network probe entirely. This keeps a brand-new host or a
        // simple wrong-password failure (ssh also exits 255 for those) from
        // making a needless extra connection.
        guard await hasStoredKey(for: host) else { return nil }

        // Build the probe args explicitly rather than reusing host.sshArguments:
        // ssh honours the *last* `-o` for a given key, so our security flags must
        // not be overridable by any option a host might one day carry. A short
        // ConnectTimeout — we only need the key-exchange round trip, not a login —
        // keeps a stored-but-unreachable host from blocking for the full default.
        var args = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=3",
            // Stay independent of the terminal's multiplexed master.
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
        ]
        if host.port != 22 { args += ["-p", String(host.port)] }
        // `--` so a leading-`-` hostname can't be read as an option; `true` is a
        // harmless remote command we never actually reach (auth/host-key first).
        // userAtHost comes from the resolved session (same source the terminal's
        // ssh uses), so this probe has no injection surface the main flow lacks.
        args += ["--", host.userAtHost, "true"]
        let stderr = await Self.runCapturingStderr("/usr/bin/ssh", args)
        return parse(stderr)
    }

    /// Whether `known_hosts` already holds a key for this host (`ssh-keygen -F`
    /// exits 0 when it finds one). A purely local lookup — no network.
    ///
    /// Gap: `ssh-keygen -F` only consults `~/.ssh/known_hosts` (and the global
    /// file). If the user points `UserKnownHostsFile` somewhere custom in their
    /// ssh_config, we'll report "no stored key", skip the probe, and not raise
    /// the overwrite prompt. The connection itself stays safe — ssh still
    /// rejects the changed key — the user just doesn't get the one-click fix.
    private static func hasStoredKey(for host: Host) async -> Bool {
        // A valid hostname never starts with `-`. We can't guard with `-F --
        // <host>`: like `-R`, ssh-keygen takes -F's operand directly and rejects
        // `--` with "Too many arguments" (verified). So just skip a leading-dash
        // name rather than risk it being read as a flag. The `[host]:port` form
        // below starts with `[`, so it's safe.
        guard !host.hostname.hasPrefix("-") else { return false }
        if await runSucceeds("/usr/bin/ssh-keygen", ["-F", host.hostname]) { return true }
        // Also try the bracketed `[host]:port` form. ssh stores this for a
        // non-default port, and for IPv6 addresses even on 22 — so always check
        // it as a fallback, not just when the port differs.
        return await runSucceeds(
            "/usr/bin/ssh-keygen", ["-F", "[\(host.hostname)]:\(host.port)"])
    }

    /// Pure classifier over `ssh`'s stderr — factored out so it can be unit
    /// tested without a live connection.
    static func parse(_ stderr: String) -> ChangedKey? {
        guard stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") else { return nil }
        return ChangedKey(newFingerprint: fingerprint(in: stderr))
    }

    /// Pull the `SHA256:…` fingerprint out of the warning, if present. Base64
    /// fingerprints contain `+` and `/` but never whitespace, so splitting on
    /// whitespace and trimming the trailing period is enough.
    private static func fingerprint(in stderr: String) -> String? {
        for token in stderr.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ".\r"))
            if cleaned.hasPrefix("SHA256:") { return cleaned }
        }
        return nil
    }

    /// Run a process and report whether it exited 0, discarding its output.
    private static func runSucceeds(_ executable: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
    }

    private static func runCapturingStderr(_ executable: String, _ args: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice
                let errPipe = Pipe()
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(bytes: data, encoding: .utf8) ?? "")
            }
        }
    }
}
