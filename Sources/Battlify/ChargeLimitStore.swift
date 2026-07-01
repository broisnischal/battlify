import Foundation
import Combine
import AppKit
import BattlifyKit

/// GUI-side state for charge limiting. Talks to the root daemon over the control
/// socket. All socket I/O happens off the main thread; published state is updated
/// back on the main actor.
@MainActor
final class ChargeLimitStore: ObservableObject {
    /// Whether the daemon is reachable (installed + running).
    @Published private(set) var daemonAvailable = false
    @Published private(set) var schemeDescription = ""
    @Published private(set) var chargingEnabled = true
    @Published private(set) var lowPowerMode = false
    /// Current sleep/idle power-feature states, keyed by pmset key.
    @Published private(set) var powerToggles: [String: Bool] = [:]

    /// Currently selected save mode (mirrors the daemon's config).
    @Published private(set) var mode: SaveMode = .off
    /// Why charging is paused, if it is ("limit"/"heat"/nil).
    @Published private(set) var pauseReason: String?

    /// Mirror of the daemon's config. Edits are pushed via `apply`.
    @Published var limitEnabled = false
    @Published var limit = 80
    @Published var heatAwareEnabled = false
    @Published var maxChargeTempC = 35.0
    @Published var magSafeLedEnabled = false
    @Published private(set) var magSafeSupported = false
    @Published var dischargeEnabled = false
    @Published private(set) var dischargeSupported = false
    @Published private(set) var discharging = false
    /// When charging is scheduled to resume (nil = not paused).
    @Published private(set) var pauseUntil: Date?
    var isPaused: Bool { pauseUntil != nil }
    var isPausedIndefinitely: Bool { (pauseUntil ?? .distantPast) > Date().addingTimeInterval(3600 * 24 * 365) }

    /// Full config last seen from the daemon, so edits preserve unrelated fields.
    private var currentConfig = BattlifyConfig.default
    private var refreshTimer: Timer?

    init() {
        refresh()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        // After wake, the daemon may have changed things (deep-save restore);
        // re-sync promptly instead of waiting for the next poll.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh() }
            }
        }
    }

    /// Pull current status from the daemon.
    func refresh() {
        Task.detached {
            let result = try? ControlClient.send(.getStatus)
            await self.ingest(result)
        }
    }

    /// Push the current GUI settings to the daemon, preserving fields the menu
    /// doesn't directly edit (mode, resumeMargin).
    func apply() {
        var cfg = currentConfig
        cfg.chargeLimitEnabled = limitEnabled
        cfg.chargeLimit = limit
        cfg.heatAwareEnabled = heatAwareEnabled
        cfg.maxChargeTempC = maxChargeTempC
        cfg.magSafeLedEnabled = magSafeLedEnabled
        cfg.dischargeEnabled = dischargeEnabled
        currentConfig = cfg
        Task.detached {
            let result = try? ControlClient.send(.setConfig(cfg))
            await self.ingest(result)
        }
    }

    /// Toggle Low Power Mode (routed through the root daemon).
    func setLowPowerMode(_ on: Bool) {
        Task.detached {
            let result = try? ControlClient.send(.setLowPowerMode(on))
            await self.ingest(result)
        }
    }

    /// Pause charging: minutes > 0 = for that long; 0 = resume; -1 = indefinitely.
    func pauseCharging(minutes: Int) {
        Task.detached {
            let result = try? ControlClient.send(.pauseCharging(minutes))
            await self.ingest(result)
        }
    }
    func resumeCharging() { pauseCharging(minutes: 0) }

    /// Apply a preset save mode (daemon-controlled parts). Returns immediately;
    /// state refreshes when the daemon replies.
    func applyMode(_ newMode: SaveMode) {
        mode = newMode // optimistic
        Task.detached {
            let result = try? ControlClient.send(.applyMode(newMode))
            await self.ingest(result)
        }
    }

    /// True when the given sleep/idle power feature is currently active.
    func isPowerToggleOn(_ toggle: PowerToggle) -> Bool {
        powerToggles[toggle.rawValue] ?? false
    }

    /// Set a sleep/idle power feature (routed through the root daemon).
    func setPowerToggle(_ toggle: PowerToggle, _ on: Bool) {
        Task.detached {
            let result = try? ControlClient.send(.setPowerToggle(toggle, on))
            await self.ingest(result)
        }
    }

    private func ingest(_ response: ControlResponse?) {
        guard let r = response else {
            daemonAvailable = false
            return
        }
        daemonAvailable = true
        currentConfig = r.config
        schemeDescription = r.schemeDescription
        chargingEnabled = r.chargingEnabled
        lowPowerMode = r.lowPowerModeEnabled
        powerToggles = r.powerToggles
        pauseReason = r.pauseReason
        mode = r.config.mode
        limitEnabled = r.config.chargeLimitEnabled
        limit = r.config.chargeLimit
        heatAwareEnabled = r.config.heatAwareEnabled
        maxChargeTempC = r.config.maxChargeTempC
        magSafeLedEnabled = r.config.magSafeLedEnabled
        magSafeSupported = r.magSafeSupported
        dischargeEnabled = r.config.dischargeEnabled
        dischargeSupported = r.dischargeSupported
        discharging = r.discharging
        pauseUntil = r.config.pauseUntil
    }
}
