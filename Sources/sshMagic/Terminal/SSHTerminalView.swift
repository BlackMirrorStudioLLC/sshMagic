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

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        Theme.apply(to: view)

        // ssh options. KeepAlive surfaces dead connections quickly so a tab
        // doesn't hang forever on a dropped link.
        var options = ["-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]

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
        // SwiftTerm drives its own layout/IO; nothing to push on SwiftUI updates.
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
