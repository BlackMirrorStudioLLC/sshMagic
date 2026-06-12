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

    init(host: Host, password: String?) {
        client = SFTPClient(host: host, password: password)
    }

    /// Connect and show the home directory. Safe to call more than once.
    func start() async {
        guard !started else { return }
        started = true
        isLoading = true
        error = nil
        do {
            try await client.connect()
            let home = try await client.home()
            await load(home)
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func refresh() async { await load(path) }

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

    /// Download a file to a local URL (used by both the Save button and the
    /// drag-to-Finder promise).
    func download(_ file: RemoteFile, to local: URL) async throws {
        transfer = "Downloading \(file.name)…"
        defer { transfer = nil }
        try await client.download(remotePath: joined(path, file.name), to: local)
    }

    func disconnect() {
        Task { await client.disconnect() }
    }

    private func load(_ newPath: String) async {
        isLoading = true
        error = nil
        do {
            let listing = try await client.list(newPath)
            path = newPath
            files = listing
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
