import Foundation
import Combine
import AppKit
import BattlifyKit

/// GUI-side charge-limit state. Socket I/O to the root daemon runs off the main
/// thread; published state is updated back on the main actor.
@MainActor
final class ChargeLimitStore: ObservableObject {
    @Published private(set) var daemonAvailable = false
    /// Protocol version the daemon reports (0 = pre-versioning).
    @Published private(set) var daemonProtocolVersion = 0
    /// Build version the daemon reports (0 = predates it).
    @Published private(set) var daemonBuildVersion = 0
    /// Installed helper is older than this build (protocol or behaviour). Triggers an
    /// automatic update (see autoUpdateHelperIfNeeded).
    var daemonOutdated: Bool {
        daemonAvailable && (daemonProtocolVersion < ControlProtocol.version
                            || daemonBuildVersion < HelperBuild.version)
    }
    @Published private(set) var schemeDescription = ""
    @Published private(set) var chargingEnabled = true
    @Published private(set) var lowPowerMode = false
    /// Sleep/idle power-feature states, keyed by pmset key.
    @Published private(set) var powerToggles: [String: Bool] = [:]

    @Published private(set) var mode: SaveMode = .off
    /// Why charging is paused ("limit"/"heat"/nil).
    @Published private(set) var pauseReason: String?

    /// Mirror of the daemon's config. Edits are pushed via `apply`.
    @Published var limitEnabled = false
    @Published var limit = 80
    /// Charging resumes at limit - resumeMargin, so the battery cycles in a band
    /// instead of sitting pinned at the limit.
    @Published var resumeMargin = 5
    var recharge: Int { limit - resumeMargin }
    /// Whether the user opted into a custom recharge range; off = default hysteresis.
    @Published var rangeEnabled: Bool = UserDefaults.standard.bool(forKey: "chargeRange.enabled") {
        didSet { UserDefaults.standard.set(rangeEnabled, forKey: "chargeRange.enabled") }
    }
    private let defaultMargin = 5

    /// Enabling seeds a sensible band; disabling reverts to default hysteresis.
    func setRangeEnabled(_ on: Bool) {
        rangeEnabled = on
        if on {
            if resumeMargin <= defaultMargin { resumeMargin = max(defaultMargin, min(20, limit - 20)) }
        } else {
            resumeMargin = defaultMargin
        }
        apply()
    }
    @Published var heatAwareEnabled = false
    @Published var maxChargeTempC = 35.0
    @Published var magSafeLedMode: MagSafeLEDMode = .status   // new-install default
    @Published private(set) var magSafeSupported = false
    @Published var dischargeEnabled = false
    @Published private(set) var dischargeSupported = false
    @Published private(set) var discharging = false
    @Published var disableChargingBeforeSleep = false
    @Published var preventIdleSleep = false
    /// "Always Active": keep the Mac awake with the lid closed (on AC power).
    @Published var keepAwake = false
    /// Opt-in: also keep awake with the lid closed on battery (drains fast / warm).
    @Published var keepAwakeOnBattery = false
    /// Keep-awake only while a matching task runs, then sleep.
    @Published var keepAwakeRequiresTask = false
    @Published var keepAwakeProcesses: [String] = []
    /// Any process at/above this %CPU counts as busy (0 = names only).
    @Published var keepAwakeMinCpu: Double = 0
    /// Release keep-awake above this °C (0 = no guardrail).
    @Published var keepAwakeMaxTempC: Double = 0
    /// Actively sleep the Mac once the monitored task finishes (task-gated keep-awake).
    @Published var sleepWhenTaskDone = false
    /// How deeply the Mac sleeps when closed and idle.
    @Published var sleepDepth: SleepDepth = .normal
    /// Spin the fans up while work is running.
    @Published var fanBoostEnabled = false
    /// Boost level as a percentage of each fan's own range.
    @Published var fanBoostPercent = 60
    /// %CPU that counts as "working" for the fan boost.
    @Published var fanBoostMinCpu: Double = 50
    /// Restrict the boost to when Always Active is holding the Mac awake.
    @Published var fanBoostOnlyWhenKeepAwake = false
    @Published var schedules: [ChargeSchedule] = []
    /// Once-daily "ready by" top-up target.
    @Published var readyBy = ReadyByTarget()
    /// Gentle (duty-cycled) charging near the top. Legacy; derived from chargePower.
    @Published var slowCharge = false
    /// Charge power as % of full rate via duty cycling (100 = full, 0 = don't charge).
    @Published var chargePower = 100
    /// One-shot calibration to 100% is in progress (auto-clears when full).
    @Published private(set) var calibrating = false
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
        t.tolerance = 15   // periodic status sync; exact timing doesn't matter
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        // After wake the daemon may have changed things (deep-save restore); re-sync promptly.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    /// Config writes in flight. While > 0 the periodic refresh must not ingest, or a
    /// stale response could clobber a fresh edit.
    private var pendingWrites = 0

    /// Pull status from the daemon (skipped while a write is outstanding).
    func refresh() {
        guard pendingWrites == 0 else { return }
        Task.detached {
            let result = try? ControlClient.send(.getStatus)
            await self.ingestFromRefresh(result)
        }
    }

    /// Ingest a getStatus response only if no config write started meanwhile.
    private func ingestFromRefresh(_ response: ControlResponse?) {
        guard pendingWrites == 0 else { return }
        ingest(response)
    }

    /// Send a config-changing request and ingest its authoritative response.
    private func command(_ request: ControlRequest) {
        pendingWrites += 1
        Task.detached {
            let result = try? ControlClient.send(request)
            await self.finishCommand(result)
        }
    }

    private func finishCommand(_ response: ControlResponse?) {
        ingest(response)
        pendingWrites = max(0, pendingWrites - 1)
    }

    private var didAttemptHelperUpdate = false

    /// Update an outdated helper once per launch via the bundled installer, so daemon
    /// fixes apply without a manual reinstall. Packaged .app only; cancel falls back to the banner.
    private func autoUpdateHelperIfNeeded() {
        guard daemonOutdated, HelperInstaller.canInstall, !didAttemptHelperUpdate else { return }
        didAttemptHelperUpdate = true
        Task.detached {
            let result = HelperInstaller.install()
            guard result.ok else { return }
            // launchd relaunches the new daemon; re-sync once it's back up.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self.refresh() }
        }
    }

    /// Push GUI settings to the daemon, preserving fields the menu doesn't edit (mode).
    func apply() {
        var cfg = currentConfig
        cfg.chargeLimitEnabled = limitEnabled
        cfg.chargeLimit = limit
        cfg.resumeMargin = resumeMargin
        cfg.heatAwareEnabled = heatAwareEnabled
        cfg.maxChargeTempC = maxChargeTempC
        cfg.magSafeLedMode = magSafeLedMode
        cfg.magSafeLedEnabled = (magSafeLedMode == .status) // keep legacy flag in sync
        cfg.dischargeEnabled = dischargeEnabled
        cfg.disableChargingBeforeSleep = disableChargingBeforeSleep
        cfg.preventIdleSleep = preventIdleSleep
        cfg.keepAwake = keepAwake
        cfg.keepAwakeOnBattery = keepAwakeOnBattery
        cfg.keepAwakeRequiresTask = keepAwakeRequiresTask
        cfg.keepAwakeProcesses = keepAwakeProcesses
        cfg.keepAwakeMinCpu = keepAwakeMinCpu
        cfg.keepAwakeMaxTempC = keepAwakeMaxTempC
        cfg.sleepWhenTaskDone = sleepWhenTaskDone
        cfg.sleepDepth = sleepDepth
        cfg.fanBoostEnabled = fanBoostEnabled
        cfg.fanBoostPercent = fanBoostPercent
        cfg.fanBoostMinCpu = fanBoostMinCpu
        cfg.fanBoostOnlyWhenKeepAwake = fanBoostOnlyWhenKeepAwake
        cfg.schedules = schedules
        cfg.readyBy = readyBy
        cfg.chargePower = chargePower
        cfg.slowCharge = chargePower < 100   // keep the legacy flag in sync
        currentConfig = cfg
        command(.setConfig(cfg))
    }

    func setLowPowerMode(_ on: Bool) {
        command(.setLowPowerMode(on))
    }

    /// Pause charging: minutes > 0 = for that long; 0 = resume; -1 = indefinitely.
    func pauseCharging(minutes: Int) {
        command(.pauseCharging(minutes))
    }
    func resumeCharging() { pauseCharging(minutes: 0) }

    /// Start / cancel a one-shot charge-to-100% calibration.
    func startCalibration() { setCalibration(true) }
    func cancelCalibration() { setCalibration(false) }
    private func setCalibration(_ on: Bool) {
        calibrating = on // optimistic
        command(.calibrateToFull(on))
    }

    /// Apply a preset save mode; state refreshes when the daemon replies.
    func applyMode(_ newMode: SaveMode) {
        mode = newMode // optimistic
        command(.applyMode(newMode))
    }

    func isPowerToggleOn(_ toggle: PowerToggle) -> Bool {
        powerToggles[toggle.rawValue] ?? false
    }

    // MARK: - Charging schedules

    func addSchedule(_ schedule: ChargeSchedule = ChargeSchedule()) {
        schedules.append(schedule)
        apply()
    }

    func updateSchedule(_ schedule: ChargeSchedule) {
        guard let i = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[i] = schedule
        apply()
    }

    func updateOrAddSchedule(_ schedule: ChargeSchedule) {
        if let i = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[i] = schedule
        } else {
            schedules.append(schedule)
        }
        apply()
    }

    func removeSchedule(_ schedule: ChargeSchedule) {
        schedules.removeAll { $0.id == schedule.id }
        apply()
    }

    var activeSchedule: ChargeSchedule? {
        schedules.first { $0.isActive(at: Date()) }
    }

    func setPowerToggle(_ toggle: PowerToggle, _ on: Bool) {
        command(.setPowerToggle(toggle, on))
    }

    /// Assign only when the value actually changed, so a status poll that returns
    /// identical state doesn't fire a burst of objectWillChange (and needless redraws).
    private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<ChargeLimitStore, T>, _ newValue: T) {
        if self[keyPath: keyPath] != newValue { self[keyPath: keyPath] = newValue }
    }

    private func ingest(_ response: ControlResponse?) {
        guard let r = response else {
            set(\.daemonAvailable, false)
            return
        }
        set(\.daemonAvailable, true)
        set(\.daemonProtocolVersion, r.daemonProtocolVersion)
        set(\.daemonBuildVersion, r.daemonBuildVersion)
        autoUpdateHelperIfNeeded()
        set(\.currentConfig, r.config)
        set(\.schemeDescription, r.schemeDescription)
        let wasChargingEnabled = chargingEnabled
        set(\.chargingEnabled, r.chargingEnabled)
        set(\.lowPowerMode, r.lowPowerModeEnabled)
        set(\.powerToggles, r.powerToggles)
        set(\.pauseReason, r.pauseReason)
        set(\.mode, r.config.mode)
        set(\.limitEnabled, r.config.chargeLimitEnabled)
        set(\.limit, r.config.chargeLimit)
        set(\.resumeMargin, r.config.resumeMargin)
        set(\.heatAwareEnabled, r.config.heatAwareEnabled)
        set(\.maxChargeTempC, r.config.maxChargeTempC)
        set(\.magSafeLedMode, r.config.magSafeLedMode)
        set(\.magSafeSupported, r.magSafeSupported)
        set(\.dischargeEnabled, r.config.dischargeEnabled)
        set(\.dischargeSupported, r.dischargeSupported)
        set(\.discharging, r.discharging)
        set(\.disableChargingBeforeSleep, r.config.disableChargingBeforeSleep)
        set(\.preventIdleSleep, r.config.preventIdleSleep)
        set(\.keepAwake, r.config.keepAwake)
        set(\.keepAwakeOnBattery, r.config.keepAwakeOnBattery)
        set(\.keepAwakeRequiresTask, r.config.keepAwakeRequiresTask)
        set(\.keepAwakeProcesses, r.config.keepAwakeProcesses)
        set(\.keepAwakeMinCpu, r.config.keepAwakeMinCpu)
        set(\.keepAwakeMaxTempC, r.config.keepAwakeMaxTempC)
        set(\.sleepWhenTaskDone, r.config.sleepWhenTaskDone)
        set(\.sleepDepth, r.config.sleepDepth)
        set(\.fanBoostEnabled, r.config.fanBoostEnabled)
        set(\.fanBoostPercent, r.config.fanBoostPercent)
        set(\.fanBoostMinCpu, r.config.fanBoostMinCpu)
        set(\.fanBoostOnlyWhenKeepAwake, r.config.fanBoostOnlyWhenKeepAwake)
        set(\.schedules, r.config.schedules)
        set(\.readyBy, r.config.readyBy)
        set(\.slowCharge, r.config.slowCharge)
        set(\.chargePower, r.config.chargePower)
        set(\.calibrating, r.config.calibrateToFull)
        set(\.pauseUntil, r.config.pauseUntil)

        // charging toggled → nudge the battery store so the menu-bar icon updates now
        if wasChargingEnabled != chargingEnabled {
            NotificationCenter.default.post(name: .battlifyChargeStateChanged, object: nil)
        }
    }
}
