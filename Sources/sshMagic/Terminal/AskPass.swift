import Foundation

/// Supplies a password to the system `ssh` non-interactively via OpenSSH's
/// `SSH_ASKPASS` mechanism — the supported way to feed a password to ssh without
/// putting it on the command line (where `ps` would expose it) or scraping the
/// terminal for the prompt.
///
/// We write the password to a private temp file (0600) and a tiny helper script
/// (0700) that prints it and immediately deletes it, so the password is read
/// exactly once and lives on disk only momentarily. `SSH_ASKPASS_REQUIRE=force`
/// makes ssh call the helper even though it has a tty.
enum AskPass {
    struct Setup {
        /// Environment entries to add to the ssh process.
        let environment: [String]
        /// Temp directory to remove once the session ends.
        let cleanupURL: URL
    }

    static func make(password: String) -> Setup? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("sshmagic-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])

            let pwURL = dir.appendingPathComponent("pw")
            try Data(password.utf8).write(to: pwURL, options: .completeFileProtection)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pwURL.path)

            // The helper prints the password then removes the file, so a single
            // read consumes it. Paths are app-generated UUIDs (no shell-unsafe
            // characters), so single-quoting is sufficient.
            let scriptURL = dir.appendingPathComponent("askpass.sh")
            let script = """
                #!/bin/sh
                cat '\(pwURL.path)'
                rm -f '\(pwURL.path)'
                """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            return Setup(
                environment: [
                    "SSH_ASKPASS=\(scriptURL.path)",
                    "SSH_ASKPASS_REQUIRE=force",
                    // Harmless on modern OpenSSH (REQUIRE=force suffices) but
                    // satisfies older builds that gate askpass on DISPLAY.
                    "DISPLAY=:0",
                ],
                cleanupURL: dir
            )
        } catch {
            return nil
        }
    }

    /// Remove the temp directory created by `make`. Safe to call repeatedly.
    static func cleanup(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
