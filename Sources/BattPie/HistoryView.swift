import SwiftUI
import Charts
import BattPieKit

struct HistoryView: View {
    @StateObject private var model = HistoryViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    description: Text("Samples are recorded every 5 minutes while BattPie runs.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                chargeChart
                if model.samples.contains(where: { $0.temp != nil }) {
                    Text("Temperature")
                        .font(.callout.weight(.semibold))
                    temperatureChart
                }
            }
        }
        .padding(18)
        .frame(width: 560, height: 460)
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
