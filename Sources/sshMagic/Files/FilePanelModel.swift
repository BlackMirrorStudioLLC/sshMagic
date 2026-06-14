import Foundation

/// Observable state for a host's file browser: current directory, its contents,
/// and in-flight transfer/loading status. Owns one `SFTPClient` for the session.
@MainActor
final class FilePanelModel: ObservableObject {
    @Published private(set) var path: String = "~"
    @Published private(set) var files: [RemoteFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var transfer: String?

    private let client: SFTPClient
    private var started = false
    /// Whether we've shown the home directory yet (so retry knows where to go).
    private var landed = false
    /// Files currently open for editing (kept alive so their watchers run).
    private var editSessions: [EditSession] = []

    init(host: Host, controlPath: String) {
        client = SFTPClient(host: host, controlPath: controlPath)
    }

    /// Connect (waiting for the terminal's session) and show home. Idempotent.
    func start() async {
        guard !started else { return }
        started = true
        await connectAndLoad()
    }

    /// Re-attempt after a failure (e.g. the terminal wasn't connected yet).
    func retry() async { await connectAndLoad() }

    func refresh() async { await load(path) }

    private func connectAndLoad() async {
        isLoading = true
        error = nil
        do {
            try await client.connect()
            let target = landed ? path : try await client.home()
            await load(target)
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            // Allow a fresh attempt if the panel is hidden and reopened (e.g. the
            // terminal connects after the panel was first shown).
            started = false
        }
    }

    func open(_ file: RemoteFile) async {
        guard file.isDirectory || file.isSymlink else { return }
        await load(joined(path, file.name))
    }

    func goUp() async {
        let parent = (path as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? "/" : parent)
    }

    func navigate(to newPath: String) async {
        await load(newPath)
    }

    func upload(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        for url in urls {
            transfer = "Uploading \(url.lastPathComponent)…"
            do {
                try await client.upload(local: url, toRemoteDir: path)
            } catch {
                self.error = error.localizedDescription
            }
        }
        transfer = nil
        await refresh()
    }

    /// Download a file to a local URL (used by the drag-to-Finder promise, which
    /// needs the throwing form to report failure to the system).
    func download(_ file: RemoteFile, to local: URL) async throws {
        transfer = "Downloading \(file.name)…"
        defer { transfer = nil }
        try await client.download(remotePath: joined(path, file.name), to: local)
    }

    /// Download to a user-chosen URL, surfacing any error in the panel.
    ///
    /// The transfer lands in the app's temp area first (never blocked by macOS
    /// folder privacy), then the app moves it into place — an app-level file op
    /// that triggers the correct Desktop/Downloads/Documents permission prompt,
    /// rather than the `sftp` subprocess writing there and being denied silently.
    func save(_ file: RemoteFile, to local: URL) async {
        transfer = "Downloading \(file.name)…"
        defer { transfer = nil }
        do {
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sshmagic-dl-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let tmp = tmpDir.appendingPathComponent(file.name)
            try await client.download(remotePath: joined(path, file.name), to: tmp)

            if FileManager.default.fileExists(atPath: local.path) {
                try FileManager.default.removeItem(at: local)
            }
            try FileManager.default.moveItem(at: tmp, to: local)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func dismissError() { error = nil }

    /// Delete a file or directory, then refresh.
    func delete(_ file: RemoteFile) async {
        do {
            try await client.remove(joined(path, file.name), isDirectory: file.isDirectory)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Open a file in an editor and keep it in sync: edits saved locally are
    /// pushed back to the host automatically.
    func edit(_ file: RemoteFile) async {
        guard !file.isDirectory else { return }
        let remotePath = joined(path, file.name)
        // Already open for editing → just bring its editor forward, rather than
        // creating a second watcher that would race uploads with the first.
        if let existing = editSessions.first(where: { $0.remotePath == remotePath }) {
            Editor.open(existing.localURL)
            return
        }
        transfer = "Opening \(file.name)…"
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sshmagic-edit-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let local = dir.appendingPathComponent(file.name)
            try await client.download(remotePath: remotePath, to: local)
            transfer = nil

            let session = EditSession(remotePath: remotePath, localURL: local, displayName: file.name)
            editSessions.append(session)
            Editor.open(local)
            startWatching(session)
        } catch {
            transfer = nil
            self.error = error.localizedDescription
        }
    }

    private func startWatching(_ session: EditSession) {
        session.watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                guard let modified = EditSession.modified(session.localURL),
                    modified > session.lastModified
                else { continue }
                await self.pushEdit(session, modified: modified)
            }
        }
    }

    private func pushEdit(_ session: EditSession, modified: Date) async {
        transfer = "Saving \(session.displayName)…"
        defer { transfer = nil }
        do {
            try await client.upload(local: session.localURL, toRemotePath: session.remotePath)
            // Only mark this version synced on success — otherwise a failed
            // upload would be skipped on the next poll instead of retried.
            session.lastModified = modified
            // If we're still showing the folder the file lives in, refresh so its
            // updated modification time appears right away.
            if (session.remotePath as NSString).deletingLastPathComponent == path {
                await refresh()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func disconnect() {
        editSessions.forEach { $0.stop() }
        editSessions.removeAll()
        Task { await client.disconnect() }
    }

    private func load(_ newPath: String) async {
        isLoading = true
        error = nil
        do {
            let listing = try await client.list(newPath)
            path = newPath
            files = listing
            landed = true
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func joined(_ base: String, _ name: String) -> String {
        if base == "/" { return "/" + name }
        return base + "/" + name
    }
}
