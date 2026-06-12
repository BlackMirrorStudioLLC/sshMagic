import Foundation

/// Talks SFTP to a host using the system `ssh`/`sftp` binaries.
///
/// On first use it opens a backgrounded **master** connection (SSH connection
/// multiplexing): that single connection authenticates once — via the same
/// askpass/Keychain password path as the terminal, or a key — and every
/// subsequent `sftp` batch op rides over it with no re-auth and no new TCP
/// handshake. That's what makes browsing feel instant.
actor SFTPClient {
    enum SFTPError: LocalizedError {
        case connection(String)
        case command(String)

        var errorDescription: String? {
            switch self {
            case .connection(let m): return "Couldn't open SFTP connection: \(m)"
            case .command(let m): return m
            }
        }
    }

    /// Result of running a helper subprocess.
    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private let host: Host
    private let password: String?
    private let controlPath: String
    /// True once the multiplexed control connection is established.
    private var controlReady = false

    init(host: Host, password: String?) {
        self.host = host
        self.password = password
        // Keep the socket path short — AF_UNIX paths are capped near 104 chars.
        self.controlPath = "/tmp/sshmagic-\(UUID().uuidString.prefix(8)).sock"
    }

    // MARK: Public API

    /// Establish the master connection (idempotent).
    func connect() async throws {
        guard !controlReady else { return }

        var env: [String: String] = [:]
        var cleanup: URL?
        if let password, !password.isEmpty, let askpass = AskPass.make(password: password) {
            for entry in askpass.environment {
                if let eq = entry.firstIndex(of: "=") {
                    env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
                }
            }
            cleanup = askpass.cleanupURL
        }
        defer { AskPass.cleanup(cleanup) }

        let args =
            [
                "-f", "-N", "-M",
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlPersist=120",
                "-o", "ControlMaster=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=12",
                "-o", "ServerAliveInterval=15",
            ] + host.sshArguments

        let result = try await Self.run("/usr/bin/ssh", args, environment: env)
        guard result.status == 0 else {
            throw SFTPError.connection(result.stderr.isEmpty ? "ssh exited \(result.status)" : result.stderr)
        }
        controlReady = true
    }

    /// The remote login/home directory.
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

    /// List a directory.
    func list(_ path: String) async throws -> [RemoteFile] {
        let out = try await runSFTP("ls -la \(Self.quote(path))")
        return RemoteFile.parse(lsOutput: out)
    }

    /// Download a remote file to a local URL.
    func download(remotePath: String, to local: URL) async throws {
        _ = try await runSFTP("get \(Self.quote(remotePath)) \(Self.quote(local.path))")
    }

    /// Upload a local file into a remote directory.
    func upload(local: URL, toRemoteDir remoteDir: String) async throws {
        let dest =
            remoteDir.hasSuffix("/")
            ? remoteDir + local.lastPathComponent
            : remoteDir + "/" + local.lastPathComponent
        _ = try await runSFTP("put \(Self.quote(local.path)) \(Self.quote(dest))")
    }

    /// Tear down the master connection.
    func disconnect() async {
        guard controlReady else { return }
        controlReady = false
        _ = try? await Self.run(
            "/usr/bin/ssh",
            ["-o", "ControlPath=\(controlPath)", "-O", "exit"] + host.sshArguments)
    }

    // MARK: Internals

    /// Run one or more sftp commands over the master in batch mode.
    private func runSFTP(_ command: String) async throws -> String {
        if !controlReady { try await connect() }

        var args = [
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
        ]
        // sftp takes the port with -P (capital), unlike ssh's -p.
        if host.port != 22 { args += ["-P", String(host.port)] }
        args += ["-b", "-", host.userAtHost]

        let result = try await Self.run("/usr/bin/sftp", args, input: command + "\n")
        guard result.status == 0 else {
            throw SFTPError.command(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout
    }

    /// Quote a path for an sftp command line (sftp does its own arg parsing, not
    /// a shell): wrap in double quotes, escaping `\` and `"`.
    private static func quote(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Run a subprocess off the actor's executor, returning its exit + output.
    private static func run(
        _ executable: String,
        _ args: [String],
        input: String? = nil,
        environment: [String: String] = [:]
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                if !environment.isEmpty {
                    var merged = ProcessInfo.processInfo.environment
                    for (key, value) in environment { merged[key] = value }
                    process.environment = merged
                }
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
