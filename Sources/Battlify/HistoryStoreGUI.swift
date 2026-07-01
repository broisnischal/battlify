import Foundation
import Combine
import BattlifyKit

/// GUI-side history: records samples to the user's history file while the app runs,
/// and loads merged samples (system daemon file + user file) for charting.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var samples: [BatterySample] = []
    @Published private(set) var lidSessions: [LidSession] = []
    @Published var range: HistoryRange = .day

    enum HistoryRange: String, CaseIterable, Identifiable {
        case sixHours = "6h"
        case day = "24h"
        case week = "7d"
        var id: String { rawValue }
        var interval: TimeInterval {
            switch self {
            case .sixHours: return 6 * 3600
            case .day: return 24 * 3600
            case .week: return 7 * 24 * 3600
            }
        }
    }

    private var recordTimer: Timer?

    init() {
        recordSample()
        reload()
        // Record our own sample every 5 minutes while running.
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordSample()
                self?.reload()
            }
        }
        t.tolerance = 60   // 5-min history sampling; a minute of drift is harmless
        RunLoop.main.add(t, forMode: .common)
        recordTimer = t
    }

    func reload() {
        let since = Date().addingTimeInterval(-range.interval)
        Task.detached {
            // Merge daemon-written and user-written samples.
            var merged = HistoryStore.load(since: since, from: BattlifyPaths.historyFile)
            merged += HistoryStore.load(since: since, from: BattlifyPaths.userHistoryFile)
            merged.sort { $0.t < $1.t }
            let sessions = LidSessionStore.recent(limit: 30).filter { $0.closedAt >= since }
            await MainActor.run {
                self.samples = merged
                self.lidSessions = sessions
            }
        }
    }

    private func recordSample() {
        let snap = BatteryMonitor.read()
        let sample = BatterySample(t: Date(), pct: snap.percentage,
                                   charging: snap.isCharging, temp: snap.temperature)
        Task.detached {
            HistoryStore.append(sample, to: BattlifyPaths.userHistoryFile)
            HistoryStore.trim(at: BattlifyPaths.userHistoryFile)
        }
    }
}
