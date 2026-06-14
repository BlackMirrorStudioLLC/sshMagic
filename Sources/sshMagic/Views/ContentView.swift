import SwiftUI

/// Root layout: sidebar + terminal area in a navigation split view.
struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            TerminalArea()
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 560)
        .alert(
            "Host Key Changed",
            isPresented: Binding(
                get: { app.hostKeyAlert != nil },
                set: { if !$0 { app.dismissHostKeyAlert() } }),
            presenting: app.hostKeyAlert
        ) { alert in
            Button("Overwrite & Reconnect", role: .destructive) {
                app.overwriteHostKeyAndReconnect(alert)
            }
            Button("Cancel", role: .cancel) { app.dismissHostKeyAlert() }
        } message: { alert in
            Text(Self.hostKeyMessage(for: alert))
        }
    }

    /// Security-aware explanation for the changed-host-key alert.
    private static func hostKeyMessage(for alert: AppState.HostKeyAlert) -> String {
        var lines = [
            "The SSH host key for \(alert.host.displayName) (\(alert.host.hostname)) "
                + "no longer matches the one saved on this Mac.",
            "",
            "This is expected if the server was rebuilt or reinstalled — but it can also "
                + "mean someone is intercepting the connection (a man-in-the-middle attack). "
                + "Only overwrite if you were expecting this change.",
        ]
        if let fingerprint = alert.fingerprint {
            lines.append("")
            lines.append("New key fingerprint:\n\(fingerprint)")
        }
        return lines.joined(separator: "\n")
    }
}
