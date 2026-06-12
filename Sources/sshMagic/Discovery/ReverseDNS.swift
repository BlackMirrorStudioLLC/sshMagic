import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Best-effort reverse DNS: turn an IPv4 address into a hostname so scanned
/// hosts can show a friendly name instead of just their number.
///
/// Uses `getnameinfo`, which goes through the system resolver — that means it
/// picks up both router/DNS-provided PTR records *and* macOS's mDNS responder
/// (so `192.168.1.x` often resolves to `something.local`). `NI_NAMEREQD` makes
/// it fail rather than echo the numeric address back when no name exists.
enum ReverseDNS {
    /// Blocking lookup — call off the main thread. Returns nil when the address
    /// has no resolvable name.
    static func hostname(for ipv4: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guard inet_pton(AF_INET, ipv4, &addr.sin_addr) == 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(
                    sa,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NAMEREQD
                )
            }
        }
        guard status == 0 else { return nil }

        // Trim a trailing dot (FQDN form) and reject a result that's just the IP.
        var name = String(cString: buffer)
        if name.hasSuffix(".") { name.removeLast() }
        return (name.isEmpty || name == ipv4) ? nil : name
    }
}
