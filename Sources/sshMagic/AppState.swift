import Combine
import Foundation
import OSLog

/// Top-level app model: owns discovery, the user's saved hosts, and the open
/// terminal tabs. A single instance is injected into the SwiftUI environment.
@MainActor
final class AppState: ObservableObject {
    /// A resolved SSH login. The password is never persisted in this struct —
    /// it lives in the Keychain and is only carried in memory while connecting.
    struct Credentials {
        let username: String
        let password: String?
    }

    /// Describes a detected host-key change awaiting the user's decision.
    struct HostKeyAlert: Identifiable, Sendable {
        let id = UUID()
        let sessionID: TerminalSession.ID
        let host: Host
        /// The fingerprint of the key the server now presents (for verification).
        let fingerprint: String?
    }

    private static let log = Logger(
        subsystem: "com.blackmirrorstudio.sshmagic", category: "appstate")

    let discovery = DiscoveryManager()

    @Published var savedHosts: [Host] = []
    @Published var sessions: [TerminalSession] = []
    @Published var selectedSessionID: TerminalSession.ID? {
        didSet { updateActiveStatsPolling() }
    }
    /// Non-nil while the credential sheet should be shown for this host.
    @Published var pendingConnect: Host?
    /// Non-nil while the "host key changed — overwrite?" alert should be shown.
    @Published var hostKeyAlert: HostKeyAlert?
    /// Non-nil to show an error when a host-key overwrite couldn't be completed.
    @Published var hostKeyError: String?
    /// Sessions whose SFTP file browser is currently visible.
    @Published var filesVisible: Set<TerminalSession.ID> = []
    /// Whether the remote-monitoring stats bar is shown under terminals.
    /// Persisted so the choice survives a restart.
    @Published var showStatsBar =
        UserDefaults.standard.object(forKey: "showStatsBar") as? Bool ?? true
    {
        didSet { UserDefaults.standard.set(showStatsBar, forKey: "showStatsBar") }
    }

    private let savedHostsURL: URL
    private var cancellables = Set<AnyCancellable>()
    /// Logins entered this run, so reconnecting doesn't re-prompt.
    private var sessionCredentials: [String: Credentials] = [:]
    /// Hosts with a biometric unlock currently in flight, so a rapid second
    /// connect request (e.g. a double-click) doesn't fire a second Touch ID
    /// prompt and open a duplicate tab.
    private var biometricInFlight: Set<String> = []
    /// Last username typed, used to pre-fill the sheet for new hosts.
    private var lastUsername: String =
        UserDefaults.standard.string(forKey: "lastUsername") ?? NSUserName()
    {
        didSet { UserDefaults.standard.set(lastUsername, forKey: "lastUsername") }
    }

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sshMagic", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        savedHostsURL = support.appendingPathComponent("hosts.json")

        // Re-publish the nested DiscoveryManager's changes as our own. SwiftUI
        // only observes `AppState`'s own @Published properties, so without this
        // forwarding, scanning state and newly-discovered hosts (which live on
        // `discovery`) would update silently and the sidebar would never refresh
        // — the "clicked Scan, nothing happened" symptom.
        discovery.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        loadSavedHosts()
        discovery.startBonjour()

        // Diagnostic hook: SSHMAGIC_AUTOSCAN=1 kicks off a subnet scan shortly
        // after launch so the discovery path can be exercised headlessly (no UI
        // automation needed). Harmless when unset.
        if ProcessInfo.processInfo.environment["SSHMAGIC_AUTOSCAN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.discovery.startSubnetScan()
            }
        }
    }

    // MARK: Connecting

    /// Entry point for "connect to this host". If we already know the login,
    /// connect straight through — but a *saved password* is unlocked with Touch
    /// ID first (falling back to typing if the fingerprint fails). Hosts with no
    /// known login raise the credential sheet.
    func requestConnect(to host: Host) {
        // Already unlocked this run.
        if let cred = sessionCredentials[host.id] {
            openSession(host: host, username: cred.username, password: cred.password)
            return
        }

        let knownUsername =
            savedHosts.first(where: { $0.id == host.id })?.username ?? host.username
        guard let username = knownUsername, !username.isEmpty else {
            pendingConnect = host
            return
        }

        let account = KeychainStore.account(username: username, hostID: host.id)
        guard KeychainStore.hasPassword(account: account) else {
            // Username known but no saved password — raise the sheet (pre-filled
            // with the username) so the password can be entered and stored,
            // rather than silently letting ssh prompt in the terminal where it
            // can never be remembered. Leave the password blank to use a key.
            pendingConnect = host
            return
        }

        // A saved password exists. Gate its use with Touch ID (when available),
        // then read it and connect; on cancel/failure fall back to the sheet.
        guard BiometricAuth.isAvailable else {
            connectWithStoredPassword(host: host, username: username, account: account)
            return
        }
        // Drop a second concurrent request for the same host: both calls arrive
        // on the main actor before the auth Task runs, so without this guard a
        // double-click would prompt twice and open two identical tabs.
        guard !biometricInFlight.contains(host.id) else { return }
        biometricInFlight.insert(host.id)
        Task { @MainActor in
            defer { self.biometricInFlight.remove(host.id) }
            let ok = await BiometricAuth.authenticate(
                reason: "Unlock the saved password for \(host.displayName)")
            if ok {
                self.connectWithStoredPassword(host: host, username: username, account: account)
            } else {
                self.pendingConnect = host
            }
        }
    }

    private func connectWithStoredPassword(host: Host, username: String, account: String) {
        if let stored = KeychainStore.password(account: account) {
            cacheAndOpen(host: host, username: username, password: stored)
        } else {
            pendingConnect = host
        }
    }

    private func cacheAndOpen(host: Host, username: String, password: String?) {
        sessionCredentials[host.id] = Credentials(username: username, password: password)
        openSession(host: host, username: username, password: password)
    }

    /// Force the credential sheet even when a login is known ("Connect As…").
    func connectAs(_ host: Host) {
        pendingConnect = host
    }

    /// Finish a connection from the sheet: remember the choices if asked, store
    /// the password in the Keychain, and open the tab.
    func connect(host: Host, username: String, password: String, remember: Bool) {
        let pw = password.isEmpty ? nil : password
        sessionCredentials[host.id] = Credentials(username: username, password: pw)
        lastUsername = username

        if remember {
            var saved = host
            saved.username = username
            upsertSavedHost(saved)
            let acct = KeychainStore.account(username: username, hostID: host.id)
            if let pw {
                KeychainStore.setPassword(pw, account: acct)
            } else {
                KeychainStore.deletePassword(account: acct)
            }
        }
        openSession(host: host, username: username, password: pw)
    }

    /// Best login suggestion to pre-fill the sheet: this host's saved username,
    /// else the last one you typed.
    func suggestedUsername(for host: Host) -> String {
        if let saved = savedHosts.first(where: { $0.id == host.id }), let u = saved.username, !u.isEmpty {
            return u
        }
        if let u = host.username, !u.isEmpty { return u }
        return lastUsername
    }

    /// Open the actual terminal tab with a resolved login and focus it.
    private func openSession(
        host: Host, username: String, password: String?, acceptNewHostKey: Bool = false
    ) {
        var resolved = host
        resolved.username = username
        let session = TerminalSession(host: resolved, password: password)
        session.acceptNewHostKey = acceptNewHostKey
        // On an ssh-level failure, probe for a changed host key (see below).
        session.onEarlyExit = { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.diagnoseHostKey(for: session)
        }
        sessions.append(session)
        // Setting the selection starts this tab's stats poller (and pauses the
        // previously-selected one) via updateActiveStatsPolling().
        selectedSessionID = session.id
    }

    // MARK: Changed host keys

    /// After an ssh-level failure, run a quick non-interactive probe to see if it
    /// was caused by a *changed* host key (a key we trusted no longer matches).
    /// If so, raise the overwrite prompt. Anything else (auth failure, network
    /// drop, unknown host) returns nil and is left as the normal closed tab.
    private func diagnoseHostKey(for session: TerminalSession) {
        // A post-overwrite reconnect (acceptNewHostKey) must never re-trigger the
        // prompt: if it still fails that's a deeper problem, not a key change to
        // re-ask about. This is the definitive guard against the prompt looping,
        // even if `ssh-keygen -R` reported success without actually removing the
        // entry (e.g. a locked known_hosts).
        guard !session.acceptNewHostKey else { return }
        // One probe/alert at a time, and only while the tab is still open.
        guard hostKeyAlert == nil,
            sessions.contains(where: { $0.id == session.id })
        else { return }
        let host = session.host
        let sessionID = session.id
        Task { @MainActor in
            guard let changed = await HostKeyCheck.detectChangedKey(for: host),
                self.sessions.contains(where: { $0.id == sessionID })
            else { return }
            // Re-check after the await: two sessions failing at once both clear
            // the synchronous guard above before either probe finishes. We only
            // show one alert at a time — log the runner-up rather than dropping
            // it silently or clobbering the visible one.
            guard self.hostKeyAlert == nil else {
                Self.log.notice(
                    "Host key change for \(host.hostname, privacy: .public) not shown — an alert is already visible")
                return
            }
            self.hostKeyAlert = HostKeyAlert(
                sessionID: sessionID, host: host, fingerprint: changed.newFingerprint)
        }
    }

    func dismissHostKeyAlert() { hostKeyAlert = nil }
    func dismissHostKeyError() { hostKeyError = nil }

    /// Forget the stale key, then reconnect (auto-accepting the new key). The
    /// reconnect is deferred until `ssh-keygen -R` finishes so it can't race the
    /// old entry — and only happens if the removal actually succeeded, so a
    /// failed removal surfaces an error instead of looping the prompt.
    func overwriteHostKeyAndReconnect(_ alert: HostKeyAlert) {
        hostKeyAlert = nil
        KnownHosts.forget(alert.host) { [weak self] removed in
            guard let self else { return }
            if removed {
                self.reconnectAfterOverwrite(alert)
            } else {
                self.hostKeyError =
                    "Couldn't remove the old host key for \(alert.host.displayName). Your "
                    + "known_hosts file may be read-only — remove the entry manually, then "
                    + "reconnect."
            }
        }
    }

    private func reconnectAfterOverwrite(_ alert: HostKeyAlert) {
        if let dead = sessions.first(where: { $0.id == alert.sessionID }) {
            closeSession(dead)
        }
        let cred = sessionCredentials[alert.host.id]
        let username = cred?.username ?? alert.host.username ?? lastUsername
        openSession(
            host: alert.host, username: username, password: cred?.password,
            acceptNewHostKey: true)
    }

    /// Show or hide the remote-monitoring bar, starting/stopping the pollers so
    /// they only run while the bar is visible.
    func toggleStatsBar() {
        showStatsBar.toggle()
        if showStatsBar {
            updateActiveStatsPolling()
        } else {
            for session in sessions { session.stats.stop() }
        }
    }

    /// Poll remote vitals only for the visible (selected) tab. Its stats bar is
    /// the only one on screen, so polling background tabs would fork an `ssh`
    /// every few seconds for nothing — the cost the review flagged for users
    /// with many tabs open. Each tab has its own control socket, so there's no
    /// cross-tab poller to share; pausing the hidden ones is the win. Switching
    /// tabs starts the newly-selected poller (CPU/net are deltas, so they read
    /// "—" for the first interval after a switch).
    private func updateActiveStatsPolling() {
        guard showStatsBar else { return }
        for session in sessions {
            if session.id == selectedSessionID {
                session.stats.start()
            } else {
                session.stats.stop()
            }
        }
    }

    /// Show or hide the SFTP file browser for a session.
    func toggleFiles(for session: TerminalSession) {
        if filesVisible.contains(session.id) {
            filesVisible.remove(session.id)
        } else {
            filesVisible.insert(session.id)
        }
    }

    func closeSession(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        session.filePanel.disconnect()
        session.stats.stop()
        filesVisible.remove(session.id)
        sessions.remove(at: index)
        if selectedSessionID == session.id {
            // Focus the neighbour that slid into this slot, else the last tab.
            selectedSessionID =
                sessions.indices.contains(index)
                ? sessions[index].id
                : sessions.last?.id
        }
    }

    // MARK: Saved hosts

    func saveHost(_ host: Host) {
        var copy = host
        copy.source = .manual
        if !savedHosts.contains(where: { $0.id == copy.id }) {
            savedHosts.append(copy)
            persistSavedHosts()
        }
    }

    /// Insert or update a saved host, preserving its username/display name. Used
    /// when "remember" is ticked on connect.
    private func upsertSavedHost(_ host: Host) {
        var copy = host
        copy.source = .manual
        if let index = savedHosts.firstIndex(where: { $0.id == copy.id }) {
            savedHosts[index].username = copy.username
            savedHosts[index].displayName = copy.displayName
        } else {
            savedHosts.append(copy)
        }
        persistSavedHosts()
    }

    /// Apply edits to a saved host. If the connection identity (host/port) or
    /// username changed, the old Keychain password and known_hosts key are no
    /// longer valid for it, so they're cleared (the password will be re-asked on
    /// next connect). A display-name/username-preserving edit keeps the password.
    func updateSavedHost(original: Host, to edited: Host, password: String?) {
        let accountUnchanged = original.id == edited.id && original.username == edited.username
        savedHosts.removeAll { $0.id == original.id }
        if !accountUnchanged, let username = original.username, !username.isEmpty {
            KeychainStore.deletePassword(
                account: KeychainStore.account(username: username, hostID: original.id))
        }
        // If the host/port changed, the old saved key won't match the new target.
        if original.id != edited.id { KnownHosts.forget(original) }
        upsertSavedHost(edited)

        // A newly-entered password is stored under the edited login; a blank one
        // leaves an unchanged login's existing password in place.
        let passwordChanged = !(password ?? "").isEmpty
        if passwordChanged, let username = edited.username, !username.isEmpty {
            KeychainStore.setPassword(
                password ?? "", account: KeychainStore.account(username: username, hostID: edited.id))
        }

        // Only drop cached creds when the login actually changed — a display-name
        // edit shouldn't force a spurious Touch ID re-prompt next connect.
        if !accountUnchanged || passwordChanged {
            sessionCredentials[original.id] = nil
            sessionCredentials[edited.id] = nil
        }
    }

    func removeSavedHost(_ host: Host) {
        savedHosts.removeAll { $0.id == host.id }
        // Forget the stored password and the SSH host key for this box.
        if let username = host.username, !username.isEmpty {
            KeychainStore.deletePassword(
                account: KeychainStore.account(username: username, hostID: host.id))
        }
        KnownHosts.forget(host)
        persistSavedHosts()
    }

    private func loadSavedHosts() {
        guard let data = try? Data(contentsOf: savedHostsURL),
            let decoded = try? JSONDecoder().decode([Host].self, from: data)
        else { return }
        savedHosts = decoded
    }

    private func persistSavedHosts() {
        guard let data = try? JSONEncoder().encode(savedHosts) else { return }
        try? data.write(to: savedHostsURL, options: .atomic)
    }
}
