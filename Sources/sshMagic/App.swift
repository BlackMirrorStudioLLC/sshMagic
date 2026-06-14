import SwiftUI

@main
struct SSHMagicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}  // no "New Window" — single-window app
        }
    }
}

/// Ensures the app behaves as a normal foreground GUI app even when launched as
/// a bare SwiftPM executable (no `.app` bundle / LSUIElement plist), and gives it
/// standard Mac close behavior: the red X hides the app to the Dock (keeping SSH
/// sessions alive) rather than quitting.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeInterceptor: WindowCloseInterceptor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Use our bundled icon for the Dock/app switcher. Harmless if absent
        // (e.g. a bare `swift run` with no bundle).
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        {
            NSApp.applicationIconImage = icon
        }

        installCloseInterceptor()
    }

    /// Closing the last window does NOT quit — the app stays in the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            sender.windows.first?.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// Install the close interceptor on the main window once SwiftUI has created
    /// it, retrying briefly until it exists (capped at ~5s so it can't spin
    /// forever if a window never appears).
    private func installCloseInterceptor(attempt: Int = 0) {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else {
            guard attempt < 25 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.installCloseInterceptor(attempt: attempt + 1)
            }
            return
        }
        guard !(window.delegate is WindowCloseInterceptor) else { return }
        let interceptor = WindowCloseInterceptor()
        interceptor.forwarding = window.delegate
        window.delegate = interceptor
        closeInterceptor = interceptor
    }
}

/// Makes the red close button hide the app — keeping the window and its SSH
/// sessions alive — instead of quitting, then forwards every other delegate call
/// to SwiftUI's own window delegate so normal behavior is unaffected.
final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    weak var forwarding: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.hide(nil)
        return false
    }

    // These override Objective-C methods whose signatures use `Selector!`.
    // swiftlint:disable implicitly_unwrapped_optional
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forwarding?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        (forwarding?.responds(to: aSelector) ?? false)
            ? forwarding : super.forwardingTarget(for: aSelector)
    }
    // swiftlint:enable implicitly_unwrapped_optional
}
