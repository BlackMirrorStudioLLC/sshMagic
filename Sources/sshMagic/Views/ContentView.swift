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
            Self.alertTitle(app.activeAlert),
            isPresented: Binding(
                get: { app.activeAlert != nil },
                set: { if !$0 { app.dismissAlert() } }),
            presenting: app.activeAlert
        ) { active in
            switch active {
            case .changedKey(let info):
                Button("Overwrite & Reconnect", role: .destructive) {
                    app.overwriteHostKeyAndReconnect(info)
                }
                Button("Cancel", role: .cancel) { app.dismissAlert() }
            case .removalFailed:
                Button("OK", role: .cancel) { app.dismissAlert() }
            }
        } message: { active in
            Text(Self.alertMessage(for: active))
        }
    }

    private static func alertTitle(_ alert: AppState.ActiveAlert?) -> String {
        switch alert {
        case .changedKey: return "Host Key Changed"
        case .removalFailed: return "Couldn't Update Host Key"
        case nil: return ""
        }
    }

    private static func alertMessage(for alert: AppState.ActiveAlert) -> String {
        switch alert {
        case .changedKey(let info): return hostKeyMessage(for: info)
        case .removalFailed(_, let message): return message
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
