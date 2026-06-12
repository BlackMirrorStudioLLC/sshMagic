import Foundation
import Network

/// Discovers SSH servers that advertise themselves over mDNS/Bonjour as
/// `_ssh._tcp`. NAS boxes, Raspberry Pis with avahi, macOS "Remote Login", and
/// most managed switches show up here without any scanning.
///
/// Uses `NWBrowser` (the modern Network.framework API) rather than the
/// deprecated `NetServiceBrowser`. Results are delivered on the main queue.
final class BonjourScanner {
    private var browser: NWBrowser?
    private let onResolve: (Host) -> Void

    init(onResolve: @escaping (Host) -> Void) {
        self.onResolve = onResolve
    }

    func start() {
        // Already running.
        guard browser == nil else { return }

        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_ssh._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                self.resolve(result)
            }
        }

        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Turn a browse result into a concrete host by opening a short-lived
    /// connection so Network.framework hands us the resolved endpoint
    /// (hostname/IP + port) behind the Bonjour service name.
    private func resolve(_ result: NWBrowser.Result) {
        guard case let .service(name, _, _, _) = result.endpoint else { return }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let endpoint = connection.currentPath?.remoteEndpoint,
                    case let .hostPort(host, port) = endpoint
                {
                    let hostname = Self.string(from: host)
                    let resolved = Host(
                        hostname: hostname,
                        port: Int(port.rawValue),
                        displayName: name,
                        source: .bonjour,
                        lastSeen: Date()
                    )
                    self?.onResolve(resolved)
                }
                connection.cancel()
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    /// Prefer a numeric IP; strip the IPv6 zone (`%en0`) so we get a clean,
    /// connectable address string.
    private static func string(from host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let addr):
            return String(describing: addr).components(separatedBy: "%").first ?? "\(addr)"
        case .ipv6(let addr):
            return String(describing: addr).components(separatedBy: "%").first ?? "\(addr)"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}
