import Foundation
import Network
import OSLog

/// Sweeps the local subnet(s) for hosts listening on a TCP port (22 by default)
/// by attempting a bounded number of concurrent connections. A successful
/// handshake → the host is reachable and almost certainly running sshd.
///
/// This complements `BonjourScanner`: plenty of SSH servers (routers, headless
/// Linux boxes without avahi) never advertise over mDNS but do answer on 22.
///
/// Threading model (deliberate, to avoid libdispatch deadlocks):
///   * The driver loop runs on a background global queue and is *allowed to
///     block* on `semaphore.wait()` — it owns no shared queue, so blocking it
///     starves nothing.
///   * NWConnection callbacks + per-probe timeouts run on `callbackQueue`
///     (concurrent). They `signal()` the semaphore the driver is waiting on.
///   * All mutable state (`cancelled`, `live`, each probe's `finished`) is
///     guarded by `lock`. Nothing ever calls `sync` on a queue it's already on.
final class SubnetScanner {
    private static let log = Logger(subsystem: "com.blackmirrorstudio.sshmagic", category: "scan")

    private let port: Int
    private let maxConcurrent: Int
    private let connectTimeout: TimeInterval

    private let semaphore: DispatchSemaphore
    private let callbackQueue = DispatchQueue(
        label: "sshmagic.subnetscanner.callbacks", attributes: .concurrent)

    private let lock = NSLock()
    private var live: [String: NWConnection] = [:]  // address → in-flight connection
    private var cancelled = false
    private var foundCount = 0

    init(port: Int = 22, maxConcurrent: Int = 64, connectTimeout: TimeInterval = 1.5) {
        self.port = port
        self.maxConcurrent = maxConcurrent
        self.connectTimeout = connectTimeout
        self.semaphore = DispatchSemaphore(value: maxConcurrent)
    }

    /// Probe every host on every active subnet. `onFound` fires on the main
    /// queue for each responsive address; `onComplete` fires once the whole
    /// sweep finishes (or is cancelled).
    func scan(onFound: @escaping (Host) -> Void, onComplete: @escaping () -> Void) {
        let targets =
            LocalNetwork.activeIPv4Interfaces()
            .flatMap { LocalNetwork.hostAddresses(for: $0) }
        // De-dup in case interfaces overlap.
        let unique = Array(Set(targets))

        lock.lock()
        foundCount = 0
        lock.unlock()

        Self.log.info("subnet scan starting on port \(self.port): \(unique.count) targets")
        guard !unique.isEmpty else {
            Self.log.notice("subnet scan: no physical LAN interfaces — nothing to probe")
            DispatchQueue.main.async { onComplete() }
            return
        }

        // The driver loop blocks on the semaphore; run it off any shared queue.
        // Capture `self` STRONGLY: a started scan must run to completion (fire
        // `onComplete`, rebalance the semaphore) even if the caller drops its
        // only reference — with `[weak self]` the driver could find `self` nil
        // before it began and silently never complete. There's no retain cycle
        // (the scanner doesn't hold this closure), so the strong hold simply
        // keeps the scanner alive for the few seconds the sweep takes, then
        // releases it.
        DispatchQueue.global(qos: .utility).async {
            let group = DispatchGroup()
            for address in unique {
                if self.isCancelled { break }
                self.semaphore.wait()
                if self.isCancelled {
                    self.semaphore.signal()
                    break
                }
                group.enter()
                self.probe(address: address, group: group, onFound: onFound)
            }
            // Block here until every launched probe has finished. This is the
            // lifetime guarantee: `self` (captured strongly via `guard let`)
            // stays alive until all `wait()`/`signal()` pairs balance, so when
            // the scanner is finally released its semaphore is back at its
            // initial value. Returning early (the old `group.notify`) let the
            // scanner deinit mid-flight and trap on an unbalanced semaphore.
            // Per-probe timeouts bound this wait to ~`connectTimeout`.
            group.wait()
            self.lock.lock()
            let found = self.foundCount
            self.lock.unlock()
            Self.log.info("subnet scan complete: \(found) host(s) found")
            DispatchQueue.main.async { onComplete() }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let connections = Array(live.values)
        live.removeAll()
        lock.unlock()
        // Cancel outside the lock; each cancellation fires a `.cancelled` state
        // change that releases its own slot via `finish`.
        for conn in connections { conn.cancel() }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func probe(
        address: String,
        group: DispatchGroup,
        onFound: @escaping (Host) -> Void
    ) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            semaphore.signal()
            group.leave()
            return
        }

        // The OS default SYN timeout is ~75s; our own `connectTimeout` below
        // bounds each probe far tighter so a silent host can't hold a slot.
        let connection = NWConnection(host: .init(address), port: nwPort, using: .tcp)

        // `finished` is guarded by `lock`: the state handler and the timeout can
        // race to complete the same probe, and exactly one must win.
        var finished = false
        let finishOnce: (Bool) -> Void = { [weak self] success in
            guard let self else { return }
            self.lock.lock()
            if finished {
                self.lock.unlock()
                return
            }
            finished = true
            self.live[address] = nil
            self.lock.unlock()

            connection.cancel()
            self.semaphore.signal()
            if success {
                self.lock.lock()
                self.foundCount += 1
                self.lock.unlock()
                Self.log.info("subnet scan found \(address, privacy: .public):\(self.port)")
                let host = Host(
                    hostname: address,
                    port: self.port,
                    displayName: address,
                    source: .scan,
                    lastSeen: Date())
                DispatchQueue.main.async { onFound(host) }
            }
            group.leave()
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finishOnce(true)
            case .failed, .cancelled:
                finishOnce(false)
            case .waiting(let error):
                // A connection-refused / no-route (closed or absent host)
                // legitimately lands here and is resolved by the timeout — far
                // too common to log at a visible level. A Local Network
                // *permission* denial also surfaces here, so this is kept at
                // .debug for diagnosis via `log stream` without spamming.
                Self.log.debug(
                    "subnet probe \(address, privacy: .public) waiting: \(error.localizedDescription, privacy: .public)"
                )
            default:
                break
            }
        }

        lock.lock()
        live[address] = connection
        lock.unlock()
        connection.start(queue: callbackQueue)

        // Hard timeout: a host that drops SYNs silently must not hold a slot.
        callbackQueue.asyncAfter(deadline: .now() + connectTimeout) {
            finishOnce(false)
        }
    }
}
