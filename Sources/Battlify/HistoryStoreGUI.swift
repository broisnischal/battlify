import Foundation
import Combine
import BattlifyKit

/// GUI-side history: records samples to the user's history file while the app runs,
/// and loads merged samples (system daemon file + user file) for charting.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var samples: [BatterySample] = []
    @Published private(set) var lidSessions: [LidSession] = []
    /// Charging runs derived from `samples`, newest first.
    @Published private(set) var chargeSessions: [ChargeSpan] = []
    /// On-battery runs derived from `samples`, newest first.
    @Published private(set) var dischargeSessions: [ChargeSpan] = []
    /// Per-day rollups derived from `samples`, newest day first.
    @Published private(set) var dailySummaries: [DailySummary] = []
    /// 30-day wear attribution, independent of the chart's `range`.
    @Published private(set) var wearReport: WearReport = .empty
    @Published var range: HistoryRange = .day

    /// Threshold (charge %) above which time counts as "high charge".
    let highChargeThreshold = SessionAnalysis.highChargeThreshold

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
        refresh()
        // Record our own sample every 5 minutes while running.
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 60   // 5-min history sampling; a minute of drift is harmless
        RunLoop.main.add(t, forMode: .common)
        recordTimer = t
    }

    /// Record the current battery reading, then load — in one task, so the load
    /// can't race ahead of the append. Call this whenever the window appears so
    /// the newest sample shows immediately (fixes "had to switch tabs to refresh").
    func refresh() {
        let snap = BatteryMonitor.read()
        let sample = BatterySample(t: Date(), pct: snap.percentage,
                                   charging: snap.isCharging, temp: snap.temperature)
        let since = Date().addingTimeInterval(-range.interval)
        Task.detached {
            HistoryStore.append(sample, to: BattlifyPaths.userHistoryFile)
            HistoryStore.trim(at: BattlifyPaths.userHistoryFile)
            await self.performLoad(since: since)
        }
    }

    /// Reload the current range without recording a new sample (used by the range
    /// picker and after clearing history).
    func reload() {
        let since = Date().addingTimeInterval(-range.interval)
        Task.detached { await self.performLoad(since: since) }
    }

    /// Load merged samples + derived data for `since` and publish on the main
    /// actor. Runs off the main thread (nonisolated) so file I/O never blocks UI.
    private nonisolated func performLoad(since: Date) async {
        // Merge daemon-written and user-written samples.
        var merged = HistoryStore.load(since: since, from: BattlifyPaths.historyFile)
        merged += HistoryStore.load(since: since, from: BattlifyPaths.userHistoryFile)
        merged.sort { $0.t < $1.t }
        let sessions = LidSessionStore.recent(limit: 30).filter { $0.closedAt >= since }

        // Charging / on-battery runs and per-day rollups, derived from the
        // same samples (newest first for display).
        let spans = SessionAnalysis.spans(from: merged)
        let charge = spans
            .filter { $0.kind == .charging && $0.duration >= 180 }
            .reversed().prefix(30).map { $0 }
        let discharge = spans
            .filter { $0.kind == .discharging && $0.duration >= 600 && $0.deltaPct < 0 }
            .reversed().prefix(30).map { $0 }
        let daily = SessionAnalysis.dailySummaries(from: merged)

        // Wear attribution always looks back 30 days, regardless of the chart range.
        let wearSince = Date().addingTimeInterval(-30 * 86_400)
        var wearSamples = HistoryStore.load(since: wearSince, from: BattlifyPaths.historyFile)
        wearSamples += HistoryStore.load(since: wearSince, from: BattlifyPaths.userHistoryFile)
        wearSamples.sort { $0.t < $1.t }
        let report = WearAnalysis.analyze(samples: wearSamples, now: Date())

        await MainActor.run {
            self.samples = merged
            self.lidSessions = sessions
            self.chargeSessions = charge
            self.dischargeSessions = discharge
            self.dailySummaries = daily
            self.wearReport = report
        }
    }

    // MARK: - Clearing history

    /// Erase the charge-sample history: the user-written file directly, and the
    /// root-owned daemon file via the helper. The chart, sessions, wear analysis
    /// and daily rollups are all derived from these samples, so they clear too.
    func clearChartHistory() {
        Task.detached {
            HistoryStore.clear(at: BattlifyPaths.userHistoryFile)
            _ = try? ControlClient.send(.clearSamples)   // daemon deletes its own file
            await MainActor.run { self.reload() }
        }
    }

    /// Erase the lid-closed session history (user-writable; no helper needed).
    func clearLidSessions() {
        Task.detached {
            LidSessionStore.clear()
            await MainActor.run { self.reload() }
        }
    }

    /// Erase everything: samples (chart, charge/discharge sessions, wear, daily)
    /// and lid sessions.
    func clearAll() {
        Task.detached {
            HistoryStore.clear(at: BattlifyPaths.userHistoryFile)
            _ = try? ControlClient.send(.clearSamples)
            LidSessionStore.clear()
            await MainActor.run { self.reload() }
        }
    }
}
