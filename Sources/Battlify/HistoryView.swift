import SwiftUI
import Charts
import BattlifyKit

struct HistoryView: View {
    @StateObject private var model = HistoryViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Battery History")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Picker("", selection: $model.range) {
                        ForEach(HistoryViewModel.HistoryRange.allCases) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .onChange(of: model.range) { _, _ in model.reload() }
                }

                if model.samples.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Samples are recorded every 5 minutes while Battlify runs.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    chargeChart
                    if model.samples.contains(where: { $0.temp != nil }) {
                        Text("Temperature").font(.callout.weight(.semibold))
                        temperatureChart
                    }
                }

                lidSessionsSection
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
        .frame(width: 560, height: 540)
    }

    // MARK: - Lid-closed sessions

    @ViewBuilder
    private var lidSessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("While Lid Was Closed")
                .font(.title3.weight(.semibold))

            if model.lidSessions.isEmpty {
                Text("No closed-lid sessions in this period yet. Close the lid and reopen it to see how much the battery drained.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.lidSessions.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Divider() }
                        lidSessionRow(s)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func lidSessionRow(_ s: LidSession) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(closedRangeText(s)).font(.callout)
                Text("\(s.closeCharge)% → \(s.openCharge)% · \(durationText(s.duration))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(s.dropPercent == 0 ? "no drop" : "−\(s.dropPercent)%")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(dropColor(s.dropPercent))
                    .monospacedDigit()
                if let rate = s.dropPerHour {
                    Text(String(format: "%.1f%%/h", rate))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func dropColor(_ drop: Int) -> Color {
        if drop == 0 { return .secondary }
        return drop >= 10 ? .red : .primary
    }

    private func closedRangeText(_ s: LidSession) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return "Closed \(f.string(from: s.closedAt))"
    }

    private func durationText(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    private var chargeChart: some View {
        Chart(model.samples) { s in
            // Shade time spent charging.
            if s.charging {
                AreaMark(
                    x: .value("Time", s.t),
                    yStart: .value("min", 0),
                    yEnd: .value("Charge", s.pct)
                )
                .foregroundStyle(.green.opacity(0.12))
            }
            LineMark(
                x: .value("Time", s.t),
                y: .value("Charge", s.pct)
            )
            .foregroundStyle(.green)
            .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...100)
        .chartYAxisLabel("Charge %")
        .frame(minHeight: 200)
    }

    private var temperatureChart: some View {
        Chart(model.samples.filter { $0.temp != nil }) { s in
            LineMark(
                x: .value("Time", s.t),
                y: .value("°C", s.temp ?? 0)
            )
            .foregroundStyle(.orange)
            .interpolationMethod(.monotone)
        }
        .chartYAxisLabel("°C")
        .frame(height: 120)
    }
}
