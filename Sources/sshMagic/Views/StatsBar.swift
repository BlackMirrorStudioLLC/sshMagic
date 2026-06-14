import SwiftUI

/// A MobaXterm-style remote-monitoring strip pinned to the bottom of a terminal:
/// live CPU, RAM, network, uptime, users, and disk usage from the remote host.
struct StatsBar: View {
    @ObservedObject var monitor: RemoteStatsMonitor
    let hostName: String

    var body: some View {
        if let stats = monitor.stats, stats.hasData {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    chip("desktopcomputer", hostName, tint: Theme.accent)
                    if let cpu = stats.cpuText { divider; chip("cpu", cpu, tint: cpuTint(stats.cpuPercent)) }
                    if let mem = stats.memText { divider; chip("memorychip", mem) }
                    if let up = stats.netUpText { divider; chip("arrow.up", up) }
                    if let down = stats.netDownText { divider; chip("arrow.down", down) }
                    if let uptime = stats.uptimeText { divider; chip("clock", uptime) }
                    if let users = stats.usersText { divider; chip("person.2", users) }
                    ForEach(stats.disks) { disk in
                        divider
                        chip("internaldrive", "\(disk.mount) \(disk.percent)%", tint: diskTint(disk.percent))
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 26)
            .background(Theme.panel)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.panelRaised)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 9)
    }

    private func chip(_ icon: String, _ value: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func cpuTint(_ percent: Double?) -> Color {
        guard let percent else { return .secondary }
        return percent > 85 ? Theme.scanTint : (percent > 50 ? .orange : Theme.bonjourTint)
    }

    private func diskTint(_ percent: Int) -> Color {
        percent > 90 ? Theme.scanTint : (percent > 75 ? .orange : .secondary)
    }
}
