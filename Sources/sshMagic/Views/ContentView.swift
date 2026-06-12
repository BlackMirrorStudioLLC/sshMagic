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
    }
}
