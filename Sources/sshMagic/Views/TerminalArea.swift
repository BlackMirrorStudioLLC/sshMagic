import SwiftUI

/// Right-hand pane: a custom tab strip across the top and the active SwiftTerm
/// surface below. Shows a welcome panel when nothing is open.
struct TerminalArea: View {
    @EnvironmentObject var app: AppState
    @State private var filePanelWidth: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            if !app.sessions.isEmpty {
                HStack(spacing: 0) {
                    TabStrip()
                    filesToggle
                }
                Divider().overlay(Theme.terminalBG)
            }
            HStack(spacing: 0) {
                terminalStack
                    .frame(maxWidth: .infinity)
                if let session = activeSession, app.filesVisible.contains(session.id) {
                    ResizableDivider(width: $filePanelWidth)
                    FilePanel(model: session.filePanel)
                        .frame(width: filePanelWidth)
                }
            }
        }
    }

    /// The persistent terminal layer — one live view per session so switching
    /// tabs (or toggling the file panel) never tears down and reconnects ssh.
    private var terminalStack: some View {
        ZStack {
            Theme.terminalBG.ignoresSafeArea()
            if let session = activeSession {
                ForEach(app.sessions) { s in
                    SSHTerminalView(session: s)
                        .opacity(s.id == session.id ? 1 : 0)
                        .allowsHitTesting(s.id == session.id)
                }
                if !session.isConnected {
                    disconnectedOverlay(session)
                }
            } else {
                WelcomePanel()
            }
        }
    }

    @ViewBuilder private var filesToggle: some View {
        if let session = activeSession {
            Button {
                app.toggleFiles(for: session)
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(app.filesVisible.contains(session.id) ? Theme.accent : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Toggle file browser (SFTP)")
            .padding(.horizontal, 10)
        }
    }

    private var activeSession: TerminalSession? {
        app.sessions.first { $0.id == app.selectedSessionID } ?? app.sessions.last
    }

    private func disconnectedOverlay(_ session: TerminalSession) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.scanTint)
            Text("Session closed")
                .font(.headline)
            if let code = session.exitCode {
                Text("ssh exited with code \(code)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Reconnect") {
                app.closeSession(session)
                // session.host carries the resolved username; the password is
                // still cached for this run, so this reconnects straight through.
                app.requestConnect(to: session.host)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// A thin draggable divider that resizes the file panel.
private struct ResizableDivider: View {
    @Binding var width: CGFloat
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Theme.panelRaised)
            .frame(width: 4)
            .overlay(Divider().overlay(Theme.terminalBG))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Capture the width at drag start so the translation
                        // (which is relative to the start) applies cleanly.
                        let base = dragStart ?? width
                        if dragStart == nil { dragStart = width }
                        // Panel sits on the right, so dragging left widens it.
                        width = min(600, max(220, base - value.translation.width))
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}

/// Custom tab strip — closeable, with the live (OSC-driven) title per tab.
private struct TabStrip: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(app.sessions) { session in
                    TabChip(session: session)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Theme.panel)
    }
}

private struct TabChip: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: TerminalSession

    private var isActive: Bool { app.selectedSessionID == session.id }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.isConnected ? Theme.bonjourTint : Theme.scanTint)
                .frame(width: 6, height: 6)
            Text(session.title)
                .font(.caption)
                .lineLimit(1)
            Button {
                app.closeSession(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isActive ? Theme.accent.opacity(0.22) : Theme.panelRaised,
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(isActive ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
        )
        .contentShape(Capsule())
        .onTapGesture { app.selectedSessionID = session.id }
        .frame(maxWidth: 220)
    }
}

private struct WelcomePanel: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.accent)
            Text("sshMagic")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Pick a host on the left to open a session,\nor scan your network to find one.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}
