import Foundation

/// How a host came to be in the list — drives the badge shown in the sidebar.
enum HostSource: String, Codable, Hashable {
    case bonjour  // advertised _ssh._tcp over mDNS
    case scan  // answered on TCP 22 during a subnet sweep
    case manual  // typed in by the user / loaded from saved hosts
}

/// A reachable (or saved) SSH endpoint.
///
/// `id` is derived from host+port so the same machine discovered by two
/// different means (Bonjour *and* the port sweep) collapses to one row instead
/// of appearing twice.
struct Host: Identifiable, Codable, Hashable {
    var hostname: String  // IP or DNS name we actually connect to
    var port: Int
    var displayName: String  // friendly label (Bonjour name, reverse-DNS, or hostname)
    var username: String?  // preferred login; nil → let ssh/ssh_config decide
    var source: HostSource
    var lastSeen: Date?

    var id: String { "\(hostname):\(port)" }

    init(
        hostname: String,
        port: Int = 22,
        displayName: String? = nil,
        username: String? = nil,
        source: HostSource = .manual,
        lastSeen: Date? = nil
    ) {
        self.hostname = hostname
        self.port = port
        self.displayName = displayName ?? hostname
        self.username = username
        self.source = source
        self.lastSeen = lastSeen
    }

    /// `user@host` when a username is known, otherwise just the host.
    var userAtHost: String {
        if let username, !username.isEmpty { return "\(username)@\(hostname)" }
        return hostname
    }

    /// argv for `/usr/bin/ssh` (excludes argv[0]). Non-default ports add `-p`.
    /// A `--` barrier precedes the destination so a hostname that begins with
    /// `-` (e.g. from a hostile mDNS responder) can't be parsed as an ssh option.
    var sshArguments: [String] {
        var args: [String] = []
        if port != 22 { args += ["-p", String(port)] }
        args += ["--", userAtHost]
        return args
    }
}
