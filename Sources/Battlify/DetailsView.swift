import SwiftUI
import BattlifyKit

/// Detached window with battery health stats and the top energy-using processes.
/// Moved out of the menu to keep the dropdown uncluttered.
struct DetailsView: View {
    @EnvironmentObject private var battery: BatteryStore
    @EnvironmentObject private var processes: ProcessMonitor
    @EnvironmentObject private var chargeLimit: ChargeLimitStore

    var body: some View {
        let snap = battery.snapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statsCard(snap)
                healthCard(snap)
                energyCard
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .frame(width: 380, height: 560)
    }

    // MARK: - Health & tips

    private func healthCard(_ snap: BatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Battery Health")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let h = snap.healthPercent {
                    Text(condition(h))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(h >= 80 ? .green : .orange)
                }
            }

            if let h = snap.healthPercent {
                HStack(spacing: 12) {
                    Text("\(h)%")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(h >= 80 ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Maximum capacity")
                            .font(.callout).foregroundStyle(.secondary)
                        if let c = snap.cycleCount {
                            Text("\(c) charge cycles")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            let tips = healthTips(snap)
            if !tips.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tips, id: \.self) { tip in
                        Label {
                            Text(tip).font(.callout).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func condition(_ health: Int) -> String {
        health >= 80 ? "Normal" : "Service Recommended"
    }

    /// Actionable, state-aware tips for reducing battery wear.
    private func healthTips(_ snap: BatterySnapshot) -> [String] {
        var tips: [String] = []

        if let t = snap.temperature, t >= 35 {
            tips.append(String(format: "Battery is warm (%.0f°C). Heat is the biggest wear factor — avoid charging in hot spots.", t))
        }
        if snap.percentage >= 95 && snap.isPluggedIn {
            tips.append("Sitting at ~100% while plugged in ages the battery faster. A charge limit keeps it lower.")
        }
        if chargeLimit.daemonAvailable {
            if !chargeLimit.limitEnabled {
                tips.append("Turn on a charge limit (80%) to cut time at high charge and slow wear.")
            }
            if !chargeLimit.heatAwareEnabled {
                tips.append("Enable “Pause charging when hot” to protect the battery from heat while charging.")
            }
        }
        if let h = snap.healthPercent, h < 80 {
            tips.append("Maximum capacity is \(h)% — Apple considers under 80% as service-recommended.")
        }
        if tips.isEmpty {
            tips.append("Your battery settings look healthy. Nice work keeping it cool and capped.")
        }
        return tips
    }

    // MARK: - Stats

    private func statsCard(_ snap: BatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Battery")
                .font(.title3.weight(.semibold))

            VStack(spacing: 0) {
                if let h = snap.healthPercent { statRow("Health", "\(h)%") }
                if let c = snap.cycleCount { Divider(); statRow("Cycle count", "\(c)") }
                if let t = snap.temperature { Divider(); statRow("Temperature", String(format: "%.1f °C", t)) }
                if let m = snap.maxCapacity, let d = snap.designCapacity {
                    Divider(); statRow("Capacity", "\(m) / \(d) mAh")
                }
                Divider(); statRow("Power source", snap.powerSource)
                Divider(); statRow("Charge", "\(snap.percentage)%")
            }
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Energy users

    private var energyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top Energy Users")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("CPU")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if processes.top.isEmpty {
                Text("No data yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(processes.top.enumerated()), id: \.element.id) { index, p in
                        if index > 0 { Divider() }
                        energyRow(p)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

                Text("Suspend pauses a process (SIGSTOP); resume continues it. Only your own processes can be paused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func energyRow(_ p: ProcessUsage) -> some View {
        HStack(spacing: 10) {
            Text(p.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(String(format: "%.0f%%", p.cpu))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            Button {
                processes.toggle(p)
            } label: {
                Image(systemName: processes.suspended.contains(p.id) ? "play.fill" : "pause.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(processes.suspended.contains(p.id) ? Color.orange : .secondary)
            .help(processes.suspended.contains(p.id) ? "Resume" : "Suspend")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
