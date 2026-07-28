import Foundation
import Combine
import BattlifyKit

/// Live fan readings for the Settings UI. Reading the SMC needs no root, so the GUI
/// does it directly; only the *writes* go through the daemon.
///
/// Polling is on-demand — nothing runs until a view asks (`beginObserving`), so a
/// closed Settings window costs nothing.
@MainActor
final class FanMonitor: ObservableObject {
    @Published private(set) var fans: [FanState] = []
    @Published private(set) var supported = false

    private let smc = SMC()
    private var control: FanControl?
    private var timer: Timer?
    private var viewers = 0
    private var opened = false

    /// Call from `.onAppear` of a view showing fan state.
    func beginObserving() {
        viewers += 1
        guard timer == nil else { return }
        openIfNeeded()
        refresh()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Call from `.onDisappear`.
    func endObserving() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func openIfNeeded() {
        guard !opened else { return }
        opened = (try? smc.open()) != nil
        guard opened else { return }
        let fanControl = FanControl(smc: smc)
        control = fanControl
        supported = fanControl.isSupported
    }

    private func refresh() {
        guard let control, supported else { return }
        let reading = control.states()
        // Only publish real changes — RPM is noisy but the view only needs the value.
        if reading != fans { fans = reading }
    }

    /// True when something has the fans off automatic control. If Battlify's own
    /// boost isn't running, that's another fan utility.
    var anyForced: Bool { fans.contains { $0.forced } }
}
