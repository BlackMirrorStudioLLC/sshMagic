import SwiftTerm
import SwiftUI

/// SwiftUI wrapper around SwiftTerm's `LocalProcessTerminalView`, configured to
/// run the system `ssh` client against a `Host` inside a real pseudo-terminal.
///
/// Running `/usr/bin/ssh` (rather than linking an in-process SSH stack) means we
/// inherit the user's `~/.ssh/config`, keys, agent, known_hosts, jump hosts and
/// password prompts for free — exactly what a power user expects.
struct SSHTerminalView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    /// Whether this is the front-most tab — drives keyboard focus.
    var isActive: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        Theme.apply(to: view)

        // Make detected URLs (and OSC 8 hyperlinks) clickable: underline on
        // hover, open on a plain click (via SwiftTerm's default NSWorkspace
        // delegate). NOTE: `.hover` is the only mode that activates *implicit*
        // (auto-detected plain-text) URLs — `.always`/`.alwaysWithModifier` only
        // apply to explicit OSC 8 hyperlinks, so a plain `https://…` printed by
        // the shell would not be clickable under those.
        view.linkHighlightMode = .hover

        // Right-click menu for copy/paste/select-all — discoverable and always
        // available regardless of which view holds focus. Items target the
        // terminal view, which implements these AppKit selectors and validates
        // them (Copy greys out with no selection, Paste with an empty clipboard).
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = NSMenuItem(
            title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for item in [copyItem, pasteItem, selectAllItem] { item.target = view }
        menu.addItem(copyItem)
        menu.addItem(pasteItem)
        menu.addItem(.separator())
        menu.addItem(selectAllItem)
        view.menu = menu

        // ssh options. KeepAlive surfaces dead connections quickly so a tab
        // doesn't hang forever on a dropped link. ControlMaster publishes this
        // authenticated connection on a socket so the SFTP file browser can
        // multiplex over it (no second authentication); ControlPersist keeps it
        // briefly alive across a momentary terminal hiccup.
        var options = [
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(session.controlPath)",
            "-o", "ControlPersist=120",
        ]

        // Inherit the login environment but force a sane TERM the remote honors.
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=\(currentLang())")

        // With a stored password, supply it via SSH_ASKPASS. We also auto-accept
        // new host keys: under SSH_ASKPASS_REQUIRE=force the yes/no host-key
        // prompt would otherwise be answered with the password and abort the
        // connection. `accept-new` still rejects *changed* keys, so a MITM swap
        // is caught.
        if let password = session.password, !password.isEmpty,
            let askpass = AskPass.make(password: password)
        {
            options += ["-o", "StrictHostKeyChecking=accept-new"]
            env.append(contentsOf: askpass.environment)
            context.coordinator.tempDir = askpass.cleanupURL
        }

        let args = options + session.host.sshArguments
        view.startProcess(
            executable: "/usr/bin/ssh",
            args: args,
            environment: env,
            execName: "ssh"
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // When this tab *becomes* the active one, grab keyboard focus so Cmd+C/V
        // and typing work without an extra click. Only act on the transition so
        // we never steal focus from the file panel on unrelated updates.
        let became = isActive && !context.coordinator.wasActive
        context.coordinator.wasActive = isActive
        if became {
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, let window = nsView.window else { return }
                if window.firstResponder !== nsView { window.makeFirstResponder(nsView) }
            }
        }
    }

    private func currentLang() -> String {
        ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8"
    }

    /// Bridges SwiftTerm's AppKit delegate callbacks back onto the observable
    /// session so SwiftUI tab titles and the connected/exit state stay live.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let session: TerminalSession
        /// Temp dir holding the askpass helper; removed when the session ends.
        var tempDir: URL?
        /// Tracks active-tab transitions so focus is only taken on the edge.
        var wasActive = false

        init(session: TerminalSession) {
            self.session = session
        }

        deinit { AskPass.cleanup(tempDir) }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            guard !title.isEmpty else { return }
            Task { @MainActor in self.session.title = title }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            AskPass.cleanup(tempDir)
            tempDir = nil
            Task { @MainActor in
                self.session.isConnected = false
                self.session.exitCode = exitCode
            }
        }
    }
}
