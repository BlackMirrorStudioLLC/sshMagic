import Foundation

/// Samples a remote Linux host's vitals (CPU, RAM, network, disk, uptime, users)
/// every few seconds by running one tiny command over the terminal's existing
/// multiplexed SSH connection — no new connection, no re-auth. CPU% and network
/// throughput are computed from the delta between successive samples.
@MainActor
final class RemoteStatsMonitor: ObservableObject {
    @Published private(set) var stats: RemoteStats?

    private let host: Host
    private let controlPath: String
    private let interval: TimeInterval = 2.5

    private struct CPUSample { let total: Int64; let idle: Int64 }
    private struct NetSample { let rx: Int64; let tx: Int64; let at: Date }

    private var loop: Task<Void, Never>?
    private var prevCPU: CPUSample?
    private var prevNet: NetSample?

    /// Per-instance startup offset so multiple tabs' pollers don't all fork an
    /// `ssh` at the same instant (e.g. when the bar is toggled on with N tabs).
    /// Explicitly `@MainActor` so the shared counter's access is a compile-time
    /// guarantee, not just a happens-to-hold-today invariant.
    @MainActor private static var instanceCount = 0
    private let stagger: TimeInterval

    /// A sentinel that can't appear in `/proc` or `who` output, so a stray line
    /// (e.g. `who` showing an `@host` suffix) can't be mistaken for a marker.
    private static let marker = "@@SSHMAGIC_"

    /// One command that emits each `/proc` source under a marker we split on.
    private static let command = [
        "echo \(marker)CPU", "head -1 /proc/stat",
        "echo \(marker)MEM", "cat /proc/meminfo",
        "echo \(marker)NET", "cat /proc/net/dev",
        "echo \(marker)UP", "cat /proc/uptime",
        "echo \(marker)DF", "df -P",
        "echo \(marker)WHO", "who | wc -l",
    ].joined(separator: "; ")

    init(host: Host, controlPath: String) {
        self.host = host
        self.controlPath = controlPath
        // Spread the first sample across the interval (0, ~0.4s, ~0.8s, …) so
        // multiple tabs don't fork their `ssh` at the same instant. The first
        // instance gets offset 0; the counter only ever feeds this `% 6` ring,
        // so its unbounded growth is harmless.
        stagger = Double(Self.instanceCount % 6) * (interval / 6)
        Self.instanceCount += 1
    }

    /// Whether the polling loop is currently active (diagnostics/tests).
    var isPolling: Bool { loop != nil }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            if self.stagger > 0 {
                try? await Task.sleep(nanoseconds: UInt64(self.stagger * 1_000_000_000))
            }
            while !Task.isCancelled {
                await self.sample()
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: Sampling

    private func sample() async {
        let args =
            [
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlMaster=no",
                "-o", "BatchMode=yes",
            ] + host.sshArguments + [Self.command]

        guard let output = await Self.run("/usr/bin/ssh", args) else {
            // Connection not up yet (or dropped) — leave the last reading.
            return
        }
        stats = parse(output)
    }

    private func parse(_ output: String) -> RemoteStats {
        var sections: [String: [String]] = [:]
        var current = ""
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix(Self.marker) {
                current = String(line.dropFirst(Self.marker.count))
                sections[current] = []
            } else {
                sections[current, default: []].append(line)
            }
        }

        var stats = RemoteStats()
        parseCPU(sections["CPU"]?.first, into: &stats)
        parseMem(sections["MEM"], into: &stats)
        parseNet(sections["NET"], into: &stats)
        if let up = sections["UP"]?.first?.split(separator: " ").first {
            stats.uptimeSeconds = Double(up)
        }
        parseDisks(sections["DF"], into: &stats)
        if let who = sections["WHO"]?.first { stats.users = Int(who.trimmingCharacters(in: .whitespaces)) }
        return stats
    }

    private func parseCPU(_ line: String?, into stats: inout RemoteStats) {
        guard let nums = line?.split(separator: " ").dropFirst().compactMap({ Int64($0) }),
            nums.count >= 5
        else { return }
        let total = nums.reduce(0, +)
        let idle = nums[3] + nums[4]  // idle + iowait
        if let prev = prevCPU {
            let dTotal = total - prev.total
            let dIdle = idle - prev.idle
            if dTotal > 0 {
                stats.cpuPercent = max(0, min(100, (1 - Double(dIdle) / Double(dTotal)) * 100))
            }
        }
        prevCPU = CPUSample(total: total, idle: idle)
    }

    private func parseMem(_ lines: [String]?, into stats: inout RemoteStats) {
        guard let lines else { return }
        var total: Int64?
        var available: Int64?
        for line in lines {
            let parts = line.split(separator: " ").filter { !$0.isEmpty }
            guard parts.count >= 2, let kb = Int64(parts[1]) else { continue }
            if line.hasPrefix("MemTotal:") { total = kb * 1024 }
            if line.hasPrefix("MemAvailable:") { available = kb * 1024 }
        }
        if let total {
            stats.memTotal = total
            if let available { stats.memUsed = max(0, total - available) }
        }
    }

    private func parseNet(_ lines: [String]?, into stats: inout RemoteStats) {
        guard let lines else { return }
        var rx: Int64 = 0
        var tx: Int64 = 0
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let iface = line[..<colon].trimmingCharacters(in: .whitespaces)
            if iface.isEmpty || iface == "lo" { continue }
            let fields = line[line.index(after: colon)...].split(separator: " ").compactMap { Int64($0) }
            if fields.count >= 9 {
                rx += fields[0]
                tx += fields[8]
            }
        }
        let now = Date()
        if let prev = prevNet {
            let dt = now.timeIntervalSince(prev.at)
            if dt > 0 {
                // Clamp to 0: a host reboot or counter wrap between samples makes
                // the delta negative, which would show as negative throughput.
                stats.netDownMbps = max(0, Double(rx - prev.rx) * 8 / 1_000_000 / dt)
                stats.netUpMbps = max(0, Double(tx - prev.tx) * 8 / 1_000_000 / dt)
            }
        }
        prevNet = NetSample(rx: rx, tx: tx, at: now)
    }

    private func parseDisks(_ lines: [String]?, into stats: inout RemoteStats) {
        guard let lines else { return }
        // Skip pseudo filesystems; keep real mounts, capped to a few.
        let skipMountPrefixes = ["/dev", "/proc", "/sys", "/run"]
        var disks: [RemoteStats.DiskUsage] = []
        for line in lines.dropFirst() {  // drop the header row
            let parts = line.split(separator: " ").filter { !$0.isEmpty }
            guard parts.count >= 6 else { continue }
            let mount = String(parts[parts.count - 1])
            guard mount.hasPrefix("/"),
                !skipMountPrefixes.contains(where: { mount == $0 || mount.hasPrefix($0 + "/") })
            else { continue }
            let pct = Int(parts[parts.count - 2].replacingOccurrences(of: "%", with: ""))
            if let pct, !disks.contains(where: { $0.mount == mount }) {
                disks.append(.init(mount: mount, percent: pct))
            }
            if disks.count >= 4 { break }
        }
        stats.disks = disks
    }

    /// Run a subprocess off-main, returning stdout (nil on non-zero exit).
    ///
    /// A watchdog terminates the child after `timeout` seconds: if the mux
    /// socket vanishes mid-command, `ssh` can otherwise hang and wedge this
    /// session's polling loop indefinitely. SIGTERM closes the pipe, which
    /// unblocks the `readDataToEndOfFile()` below.
    private static let timeout: TimeInterval = 10

    private static func run(_ executable: String, _ args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout, execute: watchdog)
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                continuation.resume(
                    returning: process.terminationStatus == 0
                        ? String(bytes: data, encoding: .utf8) : nil)
            }
        }
    }
}
