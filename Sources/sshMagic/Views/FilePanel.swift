import SwiftUI
import UniformTypeIdentifiers

/// A native-feeling remote file browser shown beside the terminal. Drag files in
/// from Finder to upload; drag rows out to Finder to download.
struct FilePanel: View {
    @ObservedObject var model: FilePanelModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.panelRaised)

            ZStack {
                Theme.panel.ignoresSafeArea()
                content
                if isDropTarget { dropOverlay }
            }
        }
        .frame(minWidth: 240)
        .background(Theme.panel)
        .task { await model.start() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(Theme.accent)
                Text("Files")
                    .font(.headline)
                Spacer()
                if model.isLoading || model.transfer != nil {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")

                Button {
                    chooseUpload()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("Upload files…")
            }

            HStack(spacing: 6) {
                Button {
                    Task { await model.goUp() }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("Parent folder")
                .disabled(model.path == "/")

                Text(model.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Theme.panel)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let error = model.error, model.files.isEmpty {
            errorState(error)
        } else if model.files.isEmpty && !model.isLoading {
            emptyState
        } else {
            List {
                ForEach(model.files) { file in
                    FileRow(file: file)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { Task { await model.open(file) } }
                        .onDrag { dragProvider(for: file) }
                        .contextMenu { rowMenu(file) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private func rowMenu(_ file: RemoteFile) -> some View {
        if file.isDirectory || file.isSymlink {
            Button {
                Task { await model.open(file) }
            } label: {
                Label("Open", systemImage: "folder")
            }
        }
        if !file.isDirectory {
            Button {
                saveToDownloads(file)
            } label: {
                Label("Download to Downloads", systemImage: "square.and.arrow.down")
            }
        }
        Divider()
        Button {
            Task { await model.refresh() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Empty folder")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Drop files here to upload")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(Theme.scanTint)
            Text("SFTP unavailable")
                .font(.callout.bold())
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Retry") { Task { await model.refresh() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .background(Theme.accent.opacity(0.08))
            .overlay(
                Label("Drop to upload to \(model.path)", systemImage: "square.and.arrow.down")
                    .font(.callout.bold())
                    .foregroundStyle(Theme.accent)
            )
            .padding(8)
            .allowsHitTesting(false)
    }

    // MARK: Drag & drop

    /// Provider for dragging a remote file out to Finder: downloads to a temp
    /// file on demand, then the system copies it to wherever it's dropped.
    private func dragProvider(for file: RemoteFile) -> NSItemProvider {
        guard !file.isDirectory else { return NSItemProvider() }
        let provider = NSItemProvider()
        provider.suggestedName = file.name
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task {
                do {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                    let dest = tmp.appendingPathComponent(file.name)
                    try await model.download(file, to: dest)
                    completion(dest, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            Task { await model.upload(urls: urls) }
        }
        return true
    }

    // MARK: Pickers

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            Task { await model.upload(urls: panel.urls) }
        }
    }

    private func saveToDownloads(_ file: RemoteFile) {
        let downloads =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dest = downloads.appendingPathComponent(file.name)
        Task { try? await model.download(file, to: dest) }
    }
}

/// A single file row: icon, name, and size/date metadata.
private struct FileRow: View {
    let file: RemoteFile

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: file.icon)
                .frame(width: 18)
                .foregroundStyle(file.isDirectory ? Theme.accent : .secondary)
            Text(file.name)
                .lineLimit(1)
            Spacer()
            if !file.sizeText.isEmpty {
                Text(file.sizeText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
    }
}
