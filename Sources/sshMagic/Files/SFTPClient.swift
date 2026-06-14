import Foundation
import OSLog

/// Talks SFTP to a host by **reusing the terminal's authenticated SSH
/// connection** via connection multiplexing. The terminal's `ssh` is the master
/// (`ControlMaster=auto` on a shared `ControlPath`); every `sftp` op here rides
/// that socket with `ControlMaster=no`, so it never re-authenticates. That's why
/// it works regardless of how you logged in — saved password, a fingerprint, a
/// key, or a password you typed straight into the terminal.
actor SFTPClient {
    enum SFTPError: LocalizedError {
        case notConnected
        case command(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Waiting for the SSH session — connect the terminal, then Retry."
            case .command(let message):
                return message
            }
        }
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static let log = Logger(subsystem: "com.blackmirrorstudio.sshmagic", category: "sftp")

    private let host: Host
    private let controlPath: String
    /// When the control socket was last confirmed live, to skip redundant
    /// `ssh -O check` forks on back-to-back operations.
    private var lastSocketOK: Date?

    init(host: Host, controlPath: String) {
        self.host = host
        self.controlPath = controlPath
    }

    // MARK: Public API

    /// Wait for the terminal's master connection to come up (it may still be
    /// authenticating — e.g. the user is typing a password). Throws if it never
    /// appears within the window so the panel can show Retry.
    func connect() async throws {
        for _ in 0..<25 {
            if await controlSocketIsUp() { return }
            // `try await` (not `try?`) so a cancellation arriving *during* the
            // sleep propagates immediately instead of looping for up to ~20s.
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        throw SFTPError.notConnected
    }

    func home() async throws -> String {
        let out = try await runSFTP("pwd")
        // sftp prints: "Remote working directory: /home/astro"
        for line in out.split(separator: "\n") where line.contains("working directory:") {
            if let range = line.range(of: ": ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return "/"
    }

    func list(_ path: String) async throws -> [RemoteFile] {
        let out = try await runSFTP("ls -la \(try Self.quote(path))")
        return RemoteFile.parse(lsOutput: out)
    }

    func download(remotePath: String, to local: URL) async throws {
        _ = try await runSFTP("get \(try Self.quote(remotePath)) \(try Self.quote(local.path))")
    }

    func upload(local: URL, toRemoteDir remoteDir: String) async throws {
        let dest =
            remoteDir.hasSuffix("/")
            ? remoteDir + local.lastPathComponent
            : remoteDir + "/" + local.lastPathComponent
        _ = try await runSFTP("put \(try Self.quote(local.path)) \(try Self.quote(dest))")
    }

    /// Upload a local file to an exact remote path (used to save edits back).
    func upload(local: URL, toRemotePath remotePath: String) async throws {
        _ = try await runSFTP("put \(try Self.quote(local.path)) \(try Self.quote(remotePath))")
    }

    /// Delete a file or directory over the master. Directories use `rm -rf`
    /// (handles non-empty); files use plain `rm -f` to keep the blast radius
    /// minimal. Callers should confirm first.
    func remove(_ remotePath: String, isDirectory: Bool) async throws {
        // Only ever delete an absolute, non-root path — a basename-stripping or
        // relative-path bug upstream must not become a catastrophic remote rm.
        let trimmed = remotePath.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), trimmed != "/" else {
            throw SFTPError.command("Refusing to delete a relative or root path.")
        }
        // Reject any `..` segment so a path can't climb out of its directory
        // (defence-in-depth: basenames are already stripped upstream).
        guard !trimmed.components(separatedBy: "/").contains("..") else {
            throw SFTPError.command("Refusing to delete a path containing '..'.")
        }
        // Reject control characters (e.g. an embedded newline a hostile server
        // could sneak into a path) before building the remote command.
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw SFTPError.command("Refusing to delete a path with control characters.")
        }
        guard await controlSocketIsUp() else { throw SFTPError.notConnected }
        // Single-quote for the remote shell; `--` stops option injection.
        let escaped = trimmed.replacingOccurrences(of: "'", with: "'\\''")
        let flags = isDirectory ? "-rf" : "-f"
        let result = try await Self.run(
            "/usr/bin/ssh",
            [
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlMaster=no",
                "-o", "BatchMode=yes",
                host.userAtHost,
                "rm \(flags) -- '\(escaped)'",
            ])
        guard result.status == 0 else {
            throw SFTPError.command(result.stderr.isEmpty ? "Delete failed." : result.stderr)
        }
    }

    /// Close the multiplexed master (called when the whole tab closes).
    func disconnect() async {
        _ = try? await Self.run(
            "/usr/bin/ssh",
            ["-o", "ControlPath=\(controlPath)", "-O", "exit"] + host.sshArguments)
    }

    // MARK: Internals

    /// True when the terminal's master socket is live (`ssh -O check`). This is a
    /// fast local check (no network), and the result is cached for a couple of
    /// seconds so back-to-back operations (browse → list → transfer) don't each
    /// fork an extra `ssh`.
    private func controlSocketIsUp() async -> Bool {
        if let last = lastSocketOK, Date().timeIntervalSince(last) < 3 { return true }
        let result = try? await Self.run(
            "/usr/bin/ssh",
            ["-o", "ControlPath=\(controlPath)", "-O", "check"] + host.sshArguments)
        let up = result?.status == 0
        lastSocketOK = up ? Date() : nil
        return up
    }

    /// Run an sftp command over the existing master (no auth, batch mode).
    private func runSFTP(_ command: String) async throws -> String {
        guard await controlSocketIsUp() else { throw SFTPError.notConnected }

        // No `-P <port>`: this always rides the master over ControlPath, and the
        // controlSocketIsUp() gate above blocks any direct-connection fallback,
        // so the port is already fixed by the master connection.
        let args = [
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
            "-b", "-", host.userAtHost,
        ]
        let result = try await Self.run("/usr/bin/sftp", args, input: command + "\n")
        guard result.status == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            Self.log.error(
                "sftp '\(command, privacy: .public)' failed (\(result.status)): \(detail, privacy: .public)")
            throw SFTPError.command(detail)
        }
        return result.stdout
    }

    /// Quote a path for an sftp command line (sftp does its own arg parsing, not
    /// a shell): wrap in double quotes, escaping `\` and `"`. Rejects control
    /// characters first — sftp batch mode reads stdin line-by-line, so a newline
    /// embedded in a hostile server's filename could split one command into two.
    /// (`remove()` applies the same guard on its own shell-out path.)
    private static func quote(_ path: String) throws -> String {
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw SFTPError.command("Refusing a path containing control characters.")
        }
        let escaped =
            path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Run a subprocess off the actor's executor, returning its exit + output.
    private static func run(
        _ executable: String,
        _ args: [String],
        input: String? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                let inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = inPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
                inPipe.fileHandleForWriting.closeFile()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(
                    returning: ProcessResult(
                        status: process.terminationStatus,
                        stdout: String(bytes: outData, encoding: .utf8) ?? "",
                        stderr: String(bytes: errData, encoding: .utf8) ?? ""
                    ))
            }
        }
    }
}
