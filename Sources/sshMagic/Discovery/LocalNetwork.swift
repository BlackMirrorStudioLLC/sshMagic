import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Helpers for figuring out which IPv4 subnet we're on, so the port sweep knows
/// which addresses to probe.
enum LocalNetwork {
    struct Interface {
        let name: String  // e.g. "en0"
        let address: UInt32  // host-order IPv4
        let netmask: UInt32  // host-order IPv4
    }

    /// The active, non-loopback IPv4 interfaces with their netmasks.
    static func activeIPv4Interfaces() -> [Interface] {
        var interfaces: [Interface] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }

            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, isRunning, !isLoopback else { continue }

            guard let addrPtr = ptr.pointee.ifa_addr,
                addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                let maskPtr = ptr.pointee.ifa_netmask
            else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            // Only sweep *physical* LAN interfaces (en0, en1, USB/Thunderbolt
            // ethernet adapters). Virtual interfaces — `bridge*` (Internet
            // Sharing, Docker, VMs), `utun*`/`ipsec*` (VPNs), `awdl*`/`llw*`
            // (AirDrop) — advertise their own private /24s that are almost never
            // real LANs, and including them balloons the sweep from one subnet to
            // many (1000+ dead probes) so the user's actual machines surface far
            // too slowly. en* is the right scope for a "find SSH boxes on my LAN"
            // scan.
            guard isPhysicalLANInterface(name) else { continue }

            let address = ipv4Value(from: addrPtr)
            let netmask = ipv4Value(from: maskPtr)
            // Skip link-local 169.254.0.0/16 — never a useful SSH target.
            guard (address >> 16) != 0xA9FE else { continue }

            interfaces.append(Interface(name: name, address: address, netmask: netmask))
        }
        return interfaces
    }

    /// True for BSD names that denote a physical/USB/Thunderbolt ethernet or
    /// Wi-Fi interface (`en0`, `en1`, …). Everything else (bridges, VPN tunnels,
    /// AirDrop links) is treated as virtual and skipped by the sweep.
    static func isPhysicalLANInterface(_ name: String) -> Bool {
        guard name.hasPrefix("en") else { return false }
        // Require `en` followed by digits, so we don't accidentally match some
        // future `enc`/`enX` virtual naming.
        let suffix = name.dropFirst(2)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// All host addresses on an interface's subnet, excluding the network and
    /// broadcast addresses and our own address. Capped so a misconfigured /8
    /// can't enqueue 16M probes.
    static func hostAddresses(for iface: Interface, maxHosts: Int = 1024) -> [String] {
        let mask = iface.netmask
        // A /23 or wider gets clamped to the local /24 to keep the sweep bounded
        // and fast; the common home case is /24 and unaffected.
        let hostBits = (~mask)
        let network = iface.address & mask
        let broadcast = network | hostBits

        var result: [String] = []
        var candidate = network &+ 1
        while candidate < broadcast {
            if candidate != iface.address {
                result.append(ipv4String(candidate))
            }
            if result.count >= maxHosts { break }
            candidate &+= 1
        }
        return result
    }

    private static func ipv4Value(from sockaddr: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
    }

    private static func ipv4String(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}
