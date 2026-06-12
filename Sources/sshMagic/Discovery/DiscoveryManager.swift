import Combine
import Foundation

/// Owns the live discovery pipeline (Bonjour + subnet sweep) and merges results
/// into a single de-duplicated, observable host list for the UI.
@MainActor
final class DiscoveryManager: ObservableObject {
    @Published private(set) var discovered: [Host] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: String = ""

    private var bonjour: BonjourScanner?
    private var subnet: SubnetScanner?
    private var byID: [String: Host] = [:]

    /// Start passive Bonjour discovery. Cheap and always-on while the app runs.
    func startBonjour() {
        guard bonjour == nil else { return }
        let scanner = BonjourScanner { [weak self] host in
            Task { @MainActor in self?.merge(host) }
        }
        bonjour = scanner
        scanner.start()
    }

    /// Kick off an active subnet port sweep. Safe to call repeatedly; a second
    /// call while a scan is running is ignored.
    func startSubnetScan() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = "Scanning local network…"

        // 128-wide with a 1s timeout sweeps a /24 in a few seconds.
        let scanner = SubnetScanner(maxConcurrent: 128, connectTimeout: 1.0)
        subnet = scanner
        scanner.scan(
            onFound: { [weak self] host in
                Task { @MainActor in self?.merge(host) }
            },
            onComplete: { [weak self] in
                Task { @MainActor in
                    self?.isScanning = false
                    self?.scanProgress = ""
                    self?.subnet = nil
                }
            }
        )
    }

    func cancelSubnetScan() {
        subnet?.cancel()
        subnet = nil
        isScanning = false
        scanProgress = ""
    }

    /// Merge a freshly discovered host. Bonjour wins on display name (it carries
    /// a friendly label); a later Bonjour hit upgrades a bare scan result.
    private func merge(_ host: Host) {
        let isNew = byID[host.id] == nil
        if var existing = byID[host.id] {
            existing.lastSeen = host.lastSeen ?? existing.lastSeen
            if host.source == .bonjour {
                existing.displayName = host.displayName
                existing.source = .bonjour
            }
            byID[host.id] = existing
        } else {
            byID[host.id] = host
        }
        rebuildDiscovered()

        // A scan only knows the IP; resolve its hostname in the background so the
        // row can show a friendly name. Bonjour hosts already carry one.
        if isNew, host.source == .scan {
            resolveHostname(for: host)
        }
    }

    /// Background reverse-DNS lookup; applies the result on the main actor.
    private func resolveHostname(for host: Host) {
        let id = host.id
        let ip = host.hostname
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let name = ReverseDNS.hostname(for: ip) else { return }
            Task { @MainActor in self?.applyHostname(name, toID: id) }
        }
    }

    /// Set a resolved hostname, but only while the row is still showing the raw
    /// IP — never clobber a Bonjour-provided friendly name.
    private func applyHostname(_ name: String, toID id: String) {
        guard var host = byID[id], host.displayName == host.hostname else { return }
        host.displayName = name
        byID[id] = host
        rebuildDiscovered()
    }

    /// Re-sort the published list: by source priority, then natural name order.
    private func rebuildDiscovered() {
        discovered = byID.values.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return sourceRank(lhs.source) < sourceRank(rhs.source)
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func sourceRank(_ source: HostSource) -> Int {
        switch source {
        case .bonjour: return 0
        case .scan: return 1
        case .manual: return 2
        }
    }
}
