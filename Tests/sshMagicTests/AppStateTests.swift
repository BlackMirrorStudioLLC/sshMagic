import Combine
import XCTest

@testable import sshMagic

@MainActor
final class AppStateTests: XCTestCase {
    /// Regression test for the "clicked Scan, nothing happened" bug: the sidebar
    /// observes `AppState`, but scanning state + discovered hosts live on the
    /// nested `AppState.discovery`. SwiftUI does not observe nested
    /// ObservableObjects automatically, so `AppState` must re-publish the
    /// discovery manager's changes. Here we assert that a change on `discovery`
    /// drives `AppState.objectWillChange` — the signal SwiftUI uses to re-render.
    func testDiscoveryChangesPropagateToAppState() {
        let app = AppState()
        let propagated = expectation(description: "AppState re-publishes discovery change")
        // A scan emits several changes (isScanning, progress, each found host);
        // we only need to observe that propagation happens at all.
        propagated.assertForOverFulfill = false

        var cancellable: AnyCancellable? = app.objectWillChange.sink {
            propagated.fulfill()
        }

        // Flipping `isScanning` (a @Published on the nested discovery manager)
        // must ripple up to AppState's own change publisher.
        app.discovery.startSubnetScan()

        wait(for: [propagated], timeout: 5)
        cancellable?.cancel()
        cancellable = nil
        app.discovery.cancelSubnetScan()
    }

    /// A discovered host with no known login must raise the credential sheet
    /// rather than silently connecting as the local user (the reported bug).
    func testConnectToUnknownHostPromptsForCredentials() {
        let app = AppState()
        let host = Host(hostname: "10.9.9.9", source: .scan)

        app.requestConnect(to: host)

        XCTAssertEqual(app.pendingConnect?.id, host.id)
        XCTAssertTrue(app.sessions.isEmpty, "should not open a tab before creds are entered")
    }

    /// After entering a username, the opened session must carry it (so ssh logs
    /// in as that user, not the local account), and a remembered login should
    /// connect straight through next time.
    func testConnectWithUsernameOpensSessionAndRemembers() {
        let app = AppState()
        let host = Host(hostname: "10.9.9.10", source: .scan)

        app.connect(host: host, username: "deploy", password: "", remember: true)

        XCTAssertEqual(app.sessions.count, 1)
        XCTAssertEqual(app.sessions.first?.host.username, "deploy")
        XCTAssertEqual(app.sessions.first?.host.userAtHost, "deploy@10.9.9.10")

        // Remembered → a second connect skips the sheet.
        app.requestConnect(to: host)
        XCTAssertNil(app.pendingConnect)
        XCTAssertEqual(app.sessions.count, 2)

        // Cleanup the saved host this test persisted.
        if let saved = app.savedHosts.first(where: { $0.id == host.id }) {
            app.removeSavedHost(saved)
        }
    }

    /// A host with a known username but no *saved password* must raise the sheet
    /// (so the password can be entered and stored), instead of connecting
    /// directly and letting ssh prompt in the terminal where it can't be saved.
    func testKnownUsernameWithoutSavedPasswordShowsSheet() {
        let app = AppState()
        // Username carried on the host; not cached this run; no Keychain password
        // for this unlikely address.
        let host = Host(hostname: "10.9.9.99", username: "deploy", source: .scan)

        app.requestConnect(to: host)

        XCTAssertEqual(app.pendingConnect?.id, host.id)
        XCTAssertTrue(app.sessions.isEmpty)
    }

    /// Only the visible (selected) tab should poll remote stats — background
    /// tabs would fork an `ssh` every few seconds for an off-screen stats bar.
    func testOnlySelectedSessionPollsStats() {
        let app = AppState()
        let original = app.showStatsBar
        app.showStatsBar = true
        defer { app.showStatsBar = original }

        app.connect(
            host: Host(hostname: "10.9.9.21", source: .scan),
            username: "u", password: "", remember: false)
        app.connect(
            host: Host(hostname: "10.9.9.22", source: .scan),
            username: "u", password: "", remember: false)
        let first = app.sessions[0]
        let second = app.sessions[1]

        // The most recently opened tab is selected, so only it polls.
        XCTAssertFalse(first.stats.isPolling)
        XCTAssertTrue(second.stats.isPolling)

        // Switching the selection moves the single active poller.
        app.selectedSessionID = first.id
        XCTAssertTrue(first.stats.isPolling)
        XCTAssertFalse(second.stats.isPolling)

        app.closeSession(first)
        app.closeSession(second)
    }

    func testSuggestedUsernameFallsBackToLastUsed() {
        let app = AppState()
        let host = Host(hostname: "10.9.9.11", source: .scan)
        // Connecting records the username as "last used".
        app.connect(host: host, username: "ops", password: "", remember: false)

        let fresh = Host(hostname: "10.9.9.12", source: .scan)
        XCTAssertEqual(app.suggestedUsername(for: fresh), "ops")
    }
}
