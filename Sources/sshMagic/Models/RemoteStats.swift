import Foundation

/// A snapshot of a remote Linux host's vitals, sampled over the SSH connection.
struct RemoteStats {
    var cpuPercent: Double?  // 0…100
    var memUsed: Int64?  // bytes
    var memTotal: Int64?
    var netUpMbps: Double?
    var netDownMbps: Double?
    var uptimeSeconds: Double?
    var users: Int?
    var disks: [DiskUsage] = []

    struct DiskUsage: Identifiable, Hashable {
        let mount: String
        let percent: Int
        var id: String { mount }
    }

    // MARK: Display

    var cpuText: String? { cpuPercent.map { "\(Int($0.rounded()))%" } }

    var memText: String? {
        guard let used = memUsed, let total = memTotal else { return nil }
        return "\(gb(used)) / \(gb(total))"
    }

    var netUpText: String? { netUpMbps.map { String(format: "%.2f Mb/s", $0) } }
    var netDownText: String? { netDownMbps.map { String(format: "%.2f Mb/s", $0) } }
    var usersText: String? { users.map { "\($0)" } }

    var uptimeText: String? {
        guard let seconds = uptimeSeconds else { return nil }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    /// True when at least one core metric parsed — i.e. the remote looks like a
    /// Linux host we can read.
    var hasData: Bool {
        cpuPercent != nil || memTotal != nil || !disks.isEmpty
    }

    private func gb(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }
}
