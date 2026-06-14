import SwiftUI
import UniformTypeIdentifiers

/// A native-feeling remote file browser shown beside the terminal. Drag files in
/// from Finder to upload; drag rows out to Finder to download.
struct FilePanel: View {
    @ObservedObject var model: FilePanelModel
    @State private var isDropTarget = false
    @State private var pendingDelete: RemoteFile?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.panelRaised)
            if let message = model.error, !model.files.isEmpty {
                errorBanner(message)
            }
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
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { file in
            Button("Delete", role: .destructive) {
                Task { await model.delete(file) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { file in
            Text(
                file.isDirectory
                    ? "This permanently deletes the folder and everything in it on the remote host."
                    : "This permanently deletes the file on the remote host.")
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
                        .onTapGesture(count: 2) {
                            Task {
                                if file.isDirectory || file.isSymlink {
                                    await model.open(file)
                                } else {
                                    await model.edit(file)
                                }
                            }
                        }
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
                Task { await model.edit(file) }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                downloadWithPanel(file)
            } label: {
                Label("Download…", systemImage: "square.and.arrow.down")
            }
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = file
        } label: {
            Label("Delete", systemImage: "trash")
        }
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
            Button("Retry") { Task { await model.retry() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A dismissible banner for operation errors (download/edit/delete) shown
    /// while a listing is still visible, so failures aren't silent.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.scanTint)
            Text(message)
                .font(.caption)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.dismissError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Theme.scanTint.opacity(0.12))
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

    /// Reliable download: the user picks the destination via a save panel, which
    /// grants write access (avoiding the silent Downloads-folder TCC failure).
    private func downloadWithPanel(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.save(file, to: url) }
        }
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
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 1)
    }

    /// "<modified>  ·  <size>" — modification time so you can see recent edits,
    /// plus the file size.
    private var subtitle: String {
        var parts: [String] = []
        if !file.modified.isEmpty { parts.append(file.modified) }
        if !file.sizeText.isEmpty { parts.append(file.sizeText) }
        return parts.joined(separator: "  ·  ")
    }
}
