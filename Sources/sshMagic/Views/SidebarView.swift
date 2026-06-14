import SwiftUI

/// Left rail: a Scan button, the live-discovered hosts, and the user's saved
/// hosts. Selecting / double-clicking a row opens a terminal tab; each row also
/// carries a "ghost" button to launch the session in Ghostty instead.
struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @State private var showAddSheet = false
    @State private var editingHost: Host?
    @State private var pendingRemove: Host?

    var body: some View {
        VStack(spacing: 0) {
            scanBar
            Divider().overlay(Theme.panelRaised)
            List {
                if !app.discovery.discovered.isEmpty {
                    Section("Discovered") {
                        ForEach(app.discovery.discovered) { host in
                            HostRow(host: host)
                        }
                    }
                }
                if !app.savedHosts.isEmpty {
                    Section("Saved") {
                        ForEach(app.savedHosts) { host in
                            HostRow(host: host)
                                .contextMenu {
                                    Button {
                                        editingHost = host
                                    } label: {
                                        Label("Edit…", systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        pendingRemove = host
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
                if app.discovery.discovered.isEmpty && app.savedHosts.isEmpty {
                    emptyState
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.panel)
        .sheet(isPresented: $showAddSheet) {
            HostEditorSheet { host in
                app.saveHost(host)
                app.requestConnect(to: host)
            }
        }
        .sheet(item: $editingHost) { host in
            HostEditorSheet(editing: host) { edited in
                app.updateSavedHost(original: host, to: edited)
            }
        }
        .sheet(item: $app.pendingConnect) { host in
            ConnectSheet(host: host, defaultUsername: app.suggestedUsername(for: host)) {
                username, password, remember in
                app.connect(host: host, username: username, password: password, remember: remember)
            }
        }
        .confirmationDialog(
            "Remove “\(pendingRemove?.displayName ?? "")”?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }),
            presenting: pendingRemove
        ) { host in
            Button("Remove", role: .destructive) {
                app.removeSavedHost(host)
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { _ in
            Text("This deletes the saved connection, its saved password, and the box's SSH host key from known_hosts.")
        }
    }

    private var scanBar: some View {
        HStack(spacing: 8) {
            Button {
                if app.discovery.isScanning {
                    app.discovery.cancelSubnetScan()
                } else {
                    app.discovery.startSubnetScan()
                }
            } label: {
                HStack(spacing: 6) {
                    if app.discovery.isScanning {
                        ProgressView().controlSize(.small)
                        Text(
                            app.discovery.discovered.isEmpty
                                ? "Scanning…"
                                : "Scanning… (\(app.discovery.discovered.count))")
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("Scan network")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)

            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .help("Add a host manually")
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(Theme.accent.opacity(0.6))
            Text("No hosts yet")
                .font(.headline)
            Text("Hit **Scan network** to sweep your subnet, or **+** to add one by hand.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .listRowBackground(Color.clear)
    }
}

/// A single host row. Clicking the row (or its terminal button) opens an
/// embedded SSH tab — MobaXterm-style, the session lives inside the app. The
/// external "Open in Ghostty" option is demoted to the right-click menu so it
/// can't be mistaken for the primary action.
private struct HostRow: View {
    @EnvironmentObject var app: AppState
    let host: Host

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.tint(for: host.source))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .lineLimit(1)
                Text(host.userAtHost + (host.port == 22 ? "" : ":\(host.port)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Primary action: connect in an embedded tab.
            Button {
                app.requestConnect(to: host)
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .help("Connect in a new tab")
        }
        .contentShape(Rectangle())
        // Single click connects in-app; this is the obvious, default behaviour.
        .onTapGesture { app.requestConnect(to: host) }
        .contextMenu {
            Button {
                app.requestConnect(to: host)
            } label: {
                Label("Connect in Tab", systemImage: "terminal")
            }
            Button {
                app.connectAs(host)
            } label: {
                Label("Connect As…", systemImage: "person.crop.circle")
            }
            if GhosttyLauncher.isAvailable {
                Button {
                    GhosttyLauncher.open(host)
                } label: {
                    Label("Open in Ghostty", systemImage: "arrow.up.forward.app")
                }
            }
            Divider()
            Button {
                app.saveHost(host)
            } label: {
                Label("Save Host", systemImage: "star")
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Save") { app.saveHost(host) }.tint(Theme.accent)
        }
    }
}
