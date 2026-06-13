import Combine
import Foundation

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

    let discovery = DiscoveryManager()

    @Published var savedHosts: [Host] = []
    @Published var sessions: [TerminalSession] = []
    @Published var selectedSessionID: TerminalSession.ID?
    /// Non-nil while the credential sheet should be shown for this host.
    @Published var pendingConnect: Host?
    /// Sessions whose SFTP file browser is currently visible.
    @Published var filesVisible: Set<TerminalSession.ID> = []
    /// Whether the remote-monitoring stats bar is shown under terminals.
    @Published var showStatsBar = true

    private let savedHostsURL: URL
    private var cancellables = Set<AnyCancellable>()
    /// Logins entered this run, so reconnecting doesn't re-prompt.
    private var sessionCredentials: [String: Credentials] = [:]
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
            // Username known, no usable saved password — connect and let ssh
            // prompt (or, for a legacy item, the sheet will re-save it).
            cacheAndOpen(host: host, username: username, password: nil)
            return
        }

        // A saved password exists. Reading it prompts for Touch ID (when the item
        // is biometric-protected); on cancel/failure we fall back to typing.
        Task { @MainActor in
            let stored = await KeychainStore.password(
                account: account, prompt: "Unlock the saved password for \(host.displayName)")
            if let stored {
                self.cacheAndOpen(host: host, username: username, password: stored)
            } else {
                self.pendingConnect = host
            }
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
    private func openSession(host: Host, username: String, password: String?) {
        var resolved = host
        resolved.username = username
        let session = TerminalSession(host: resolved, password: password)
        sessions.append(session)
        selectedSessionID = session.id
        if showStatsBar { session.stats.start() }
    }

    /// Show or hide the remote-monitoring bar, starting/stopping the per-session
    /// pollers so they only run while the bar is visible.
    func toggleStatsBar() {
        showStatsBar.toggle()
        for session in sessions {
            if showStatsBar { session.stats.start() } else { session.stats.stop() }
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

    func removeSavedHost(_ host: Host) {
        savedHosts.removeAll { $0.id == host.id }
        // Forget any stored password too.
        if let username = host.username, !username.isEmpty {
            KeychainStore.deletePassword(
                account: KeychainStore.account(username: username, hostID: host.id))
        }
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
