import Foundation
import IOKit
import IOKit.pwr_mgt
import BattlifyKit

/// The enforcement loop plus the control server.
///
/// - Periodically (and on demand) reads the shared config and battery level, then
///   enables/disables charging to hold the configured limit.
/// - Hysteresis: charging stops at >= limit and resumes only once the level drops
///   below (limit - resumeMargin), preventing rapid toggling at the threshold.
/// - Safety: on SIGTERM/SIGINT it re-enables charging, so it never leaves the Mac
///   unable to charge.
///
/// SMC access is serialized with a lock because the tick loop and the control
/// server's connection handler can both touch the SMC.
///
/// `@unchecked Sendable`: all mutable state is reached only while holding `lock`.
final class Daemon: @unchecked Sendable {
    private let smc = SMC()
    private let charge: ChargeController
    private let lock = NSLock()

    // History sampling: tick is every 10s; sample every 30 ticks (~5 min).
    private var ticksSinceSample = 0
    private let ticksPerSample = 30

    // Why charging is currently paused ("limit"/"heat"/nil), for status reporting.
    private var lastPauseReason: String?
    // °C below maxChargeTempC at which heat-paused charging may resume.
    private let heatResumeMargin = 2.0
    // Last MagSafe LED we set, so we only write the SMC on change.
    private var lastLed: MagSafeLED?

    // Post-wake settling: the daemon can't observe wake directly, so a tick loop
    // gap far larger than the tick interval implies the Mac just slept. During the
    // settle window we hold charging off and show the LED off, matching `batt`.
    private var lastTickAt: Date?
    private var settleUntil: Date?
    private let tickInterval = 10.0
    private let wakeGapThreshold = 30.0   // gap implying a sleep occurred
    private let wakeSettleDuration = 15.0 // how long to settle after wake

    // Signal handling via DispatchSource (see installSignalHandlers): the sources
    // fire cleanup on this queue in a normal context, not an async-signal handler.
    private let signalQueue = DispatchQueue(label: "com.battlify.helper.signals")
    private var signalSources: [DispatchSourceSignal] = []

    // Held IOPMAssertion preventing idle sleep (0 = none held).
    private var idleSleepAssertion: IOPMAssertionID = 0

    // "Always Active": held assertion + last-written pmset disablesleep state
    // (nil = not yet written this run) so we only shell out to pmset on change.
    private var keepAwakeAssertion: IOPMAssertionID = 0
    private var lastDisableSleep: Bool?

    // Charge-power duty cycle, done in long phases to avoid flicker/hardware
    // thrash: each charge/rest phase lasts at least `minChargeDwell`, and the
    // on:off ratio sets the average charge power. `chargeCycleCharging` is the
    // current phase; `chargeCyclePhaseStart` is when it began.
    private let minChargeDwell: TimeInterval = 120   // ≥ 2 min per phase
    private var chargeCycleCharging = true
    private var chargeCyclePhaseStart: Date?

    // Short cache for pmset-derived state (Low Power Mode + sleep toggles), which
    // each fork `pmset`. status() runs on every getStatus/command, so cache the
    // reads briefly and invalidate whenever the daemon changes them itself.
    private var pmsetCacheAt: Date?
    private var pmsetCacheLPM = false
    private var pmsetCacheToggles: [String: Bool] = [:]
    private let pmsetCacheTTL: TimeInterval = 5

    init() {
        charge = ChargeController(smc: smc)
    }

    static func run() {
        Daemon().start()
    }

    private func start() {
        do { try smc.open() } catch {
            err("cannot open SMC: \(error)")
            exit(2)
        }
        guard charge.isChargingControlSupported else {
            err("charge control not supported on this Mac")
            exit(3)
        }

        installSignalHandlers()

        let server = ControlServer { [weak self] req in
            self?.handle(req) ?? Self.failureResponse()
        }
        server.start()

        log("daemon started (scheme: \(charge.schemeDescription))")

        while true {
            lock.lock()
            tick()
            lock.unlock()
            Thread.sleep(forTimeInterval: tickInterval)
        }
    }

    // MARK: - Control handler (called from server thread)

    private func handle(_ request: ControlRequest) -> ControlResponse {
        lock.lock()
        defer { lock.unlock() }

        switch request {
        case .getStatus:
            return status(ok: true)

        case .setConfig(let incoming):
            var cfg = incoming
            cfg.chargeLimit = min(100, max(20, cfg.chargeLimit))
            // Allow a wide recharge band (up to 40%) but never let the recharge
            // floor (limit - margin) drop below 20% battery.
            cfg.resumeMargin = max(1, min(cfg.resumeMargin, 40, cfg.chargeLimit - 20))
            do {
                try ConfigStore.save(cfg)
                tick() // apply immediately
                return status(ok: true, message: "saved")
            } catch {
                return status(ok: false, message: "save failed: \(error)")
            }

        case .setLowPowerMode(let on):
            let ok = LowPowerMode.set(on)
            invalidatePmsetCache()
            return status(ok: ok, message: ok ? "lowpowermode set" : "pmset failed")

        case .setPowerToggle(let toggle, let on):
            let ok = PowerSettings.set(toggle, on)
            invalidatePmsetCache()
            return status(ok: ok, message: ok ? "\(toggle.rawValue) set" : "pmset failed")

        case .applyMode(let mode):
            return applyMode(mode)

        case .pauseCharging(let minutes):
            var cfg = ConfigStore.load()
            if minutes == 0 {
                cfg.pauseUntil = nil
            } else if minutes < 0 {
                cfg.pauseUntil = Date.distantFuture
            } else {
                cfg.pauseUntil = Date().addingTimeInterval(Double(minutes) * 60)
            }
            do { try ConfigStore.save(cfg); tick(); return status(ok: true, message: "pause updated") }
            catch { return status(ok: false, message: "save failed: \(error)") }

        case .prepareForSleep:
            // Cut charging before sleep so macOS can't top up past the limit while
            // the daemon is frozen. The SMC inhibit persists through sleep; the
            // next tick after wake re-evaluates and resumes charging if needed.
            let cfg = ConfigStore.load()
            if cfg.disableChargingBeforeSleep && cfg.chargeLimitEnabled {
                try? charge.disableCharging()
                lastPauseReason = "sleep"
                return status(ok: true, message: "charging cut for sleep")
            }
            return status(ok: true, message: "no-op")

        case .calibrateToFull(let on):
            var cfg = ConfigStore.load()
            cfg.calibrateToFull = on
            do { try ConfigStore.save(cfg); tick()
                 return status(ok: true, message: on ? "calibration started" : "calibration cancelled") }
            catch { return status(ok: false, message: "save failed: \(error)") }

        case .clearSamples:
            // Delete the root-owned history file the GUI can't touch itself.
            // Reset the sample counter so we don't immediately re-append mid-tick.
            HistoryStore.clear()
            ticksSinceSample = 0
            return status(ok: true, message: "history cleared")
        }
    }

    /// Apply all daemon-controlled parts of a save mode (charge limit, Low Power
    /// Mode, sleep wake-ups). The GUI applies the lid-radio prefs separately.
    private func applyMode(_ mode: SaveMode) -> ControlResponse {
        let p = mode.profile
        var cfg = ConfigStore.load()
        cfg.mode = mode
        cfg.chargeLimitEnabled = p.chargeLimitEnabled
        cfg.chargeLimit = p.chargeLimit
        cfg.heatAwareEnabled = p.heatAwareEnabled
        cfg.maxChargeTempC = p.maxChargeTempC
        do { try ConfigStore.save(cfg) } catch {
            return status(ok: false, message: "save failed: \(error)")
        }

        LowPowerMode.set(p.lowPowerMode)
        PowerSettings.set(.powerNap, p.powerNap)
        PowerSettings.set(.wakeOnNetwork, p.wakeOnNetwork)
        PowerSettings.set(.tcpKeepAlive, p.tcpKeepAlive)
        invalidatePmsetCache()

        tick() // enforce charge limit immediately
        return status(ok: true, message: "mode \(mode.rawValue)")
    }

    /// pmset-derived state, cached for `pmsetCacheTTL` to avoid forking `pmset`
    /// on every status call. Invalidated when the daemon changes these settings.
    private func pmsetState() -> (lpm: Bool, toggles: [String: Bool]) {
        if let at = pmsetCacheAt, Date().timeIntervalSince(at) < pmsetCacheTTL {
            return (pmsetCacheLPM, pmsetCacheToggles)
        }
        pmsetCacheLPM = LowPowerMode.isEnabled()
        pmsetCacheToggles = PowerSettings.readToggles()
        pmsetCacheAt = Date()
        return (pmsetCacheLPM, pmsetCacheToggles)
    }

    private func invalidatePmsetCache() { pmsetCacheAt = nil }

    private func status(ok: Bool, message: String? = nil) -> ControlResponse {
        let snap = BatteryMonitor.read()
        let pmset = pmsetState()
        return ControlResponse(
            ok: ok,
            config: ConfigStore.load(),
            batteryPercent: snap.percentage,
            chargingEnabled: (try? charge.isChargingEnabled()) ?? false,
            schemeDescription: charge.schemeDescription,
            lowPowerModeEnabled: pmset.lpm,
            powerToggles: pmset.toggles,
            pauseReason: lastPauseReason,
            magSafeSupported: charge.isMagSafeSupported,
            dischargeSupported: charge.isAdapterControlSupported,
            discharging: charge.isAdapterControlSupported && !((try? charge.isAdapterEnabled()) ?? true),
            message: message
        )
    }

    private static func failureResponse() -> ControlResponse {
        ControlResponse(ok: false, config: .default, batteryPercent: 0,
                        chargingEnabled: false, schemeDescription: "n/a",
                        lowPowerModeEnabled: false, powerToggles: [:],
                        pauseReason: nil, magSafeSupported: false,
                        dischargeSupported: false, discharging: false,
                        message: "daemon unavailable")
    }

    // MARK: - Enforcement (caller holds lock)

    private func tick() {
        var cfg = ConfigStore.load()
        let snap = BatteryMonitor.read()
        let level = snap.percentage
        let now = Date()

        recordHistoryIfDue(snap)

        // Detect wake: a tick gap much larger than the interval means we slept.
        if let last = lastTickAt, now.timeIntervalSince(last) > wakeGapThreshold {
            settleUntil = now.addingTimeInterval(wakeSettleDuration)
            log("woke from sleep; settling for \(Int(wakeSettleDuration))s")
        }
        lastTickAt = now

        // Expired scheduled pause → clear it and persist.
        if let until = cfg.pauseUntil, now >= until {
            cfg.pauseUntil = nil
            try? ConfigStore.save(cfg)
        }
        let paused = cfg.pauseUntil != nil

        // One-shot calibration ends the moment the battery reaches full.
        if cfg.calibrateToFull && (snap.isFullyCharged || level >= 100) {
            cfg.calibrateToFull = false
            try? ConfigStore.save(cfg)
            log("calibration complete (battery full)")
        }

        // We only actively manage charging when limiting or heat-pausing is on.
        let managing = cfg.chargeLimitEnabled || cfg.heatAwareEnabled
        // Settling only holds charging when we'd otherwise be managing it.
        let settling = managing && (settleUntil.map { now < $0 } ?? false)

        let charging = (try? charge.isChargingEnabled()) ?? true
        // Recurring schedule window active right now (first match wins), and the
        // "ready by" top-up state — both influence the charge decision below.
        let activeSchedule = cfg.schedules.first { $0.isActive(at: now) }
        let topUp = topUpBypassActive(cfg, level: level, now: now)
        var desired = true
        var reason: String? = nil

        if paused {
            // Scheduled pause overrides everything: just don't charge.
            desired = false; reason = "paused"
        } else if settling {
            // Hold charging off briefly after wake before resuming control.
            desired = false; reason = "settling"
        } else if let s = activeSchedule, s.action == .hold || s.action == .discharge {
            // A hold/discharge window keeps charging off (discharge is driven in
            // manageDischarge). A "charge" window falls through to normal logic.
            desired = false; reason = "schedule"
        } else {
            // A "charge" schedule window and ready-by top-up both bypass the limit
            // ceiling (charge toward 100 / the target). Calibration does too.
            let bypassLimit = cfg.calibrateToFull || topUp || (activeSchedule?.action == .charge)

            // Charge-limit constraint, with a hysteresis band.
            if cfg.chargeLimitEnabled && !bypassLimit {
                if level >= cfg.chargeLimit {
                    desired = false; reason = "limit"
                } else if level >= cfg.chargeLimit - cfg.resumeMargin && !charging {
                    desired = false; reason = "limit"   // hold paused inside the band
                }
            }
            // Heat constraint (only while we'd otherwise charge).
            if desired, cfg.heatAwareEnabled, let t = snap.temperature {
                if t >= cfg.maxChargeTempC {
                    desired = false; reason = "heat"
                } else if t >= cfg.maxChargeTempC - heatResumeMargin
                            && !charging && lastPauseReason == "heat" {
                    desired = false; reason = "heat"
                }
            }
        }

        // Duty-cycle charging to the requested power. The LED follows the charging
        // regime (steady) rather than each on/off phase, so it doesn't flicker.
        let enable = chargeDutyGate(desired: desired, power: cfg.chargePower, now: now)
        let chargingRegime = desired && cfg.chargePower > 0

        lastPauseReason = desired ? (enable ? nil : "slow") : reason
        ensure(enabled: enable, current: charging)
        manageDischarge(cfg, snap, scheduleDischarge: activeSchedule?.action == .discharge)
        updateMagSafeLED(cfg, snap, charging: chargingRegime, settling: settling)
        updateIdleSleepAssertion(cfg, snap)
        updateKeepAwake(cfg, snap)
    }

    /// Whether to charge this tick for the requested power (0–100%). 100% is a
    /// passthrough; below 100% it duty-cycles in long phases (each ≥ `minChargeDwell`)
    /// so charging toggles at most once every couple of minutes rather than flickering
    /// the charge indicators and thrashing the charger hardware.
    private func chargeDutyGate(desired: Bool, power: Int, now: Date) -> Bool {
        // Reset when not charging so it resumes promptly in a fresh charge phase.
        guard desired else {
            chargeCyclePhaseStart = nil; chargeCycleCharging = true; return false
        }
        let p = min(100, max(0, power))
        if p >= 100 { chargeCyclePhaseStart = nil; chargeCycleCharging = true; return true }
        if p <= 0  { chargeCyclePhaseStart = nil; chargeCycleCharging = false; return false }

        // The minority phase gets the 2-minute floor; the majority phase is
        // stretched to hit the requested ratio. So both phases are always ≥ 2 min.
        let onTime: TimeInterval
        let offTime: TimeInterval
        if p <= 50 {
            onTime = minChargeDwell
            offTime = minChargeDwell * Double(100 - p) / Double(p)
        } else {
            offTime = minChargeDwell
            onTime = minChargeDwell * Double(p) / Double(100 - p)
        }

        guard let start = chargeCyclePhaseStart else {
            chargeCyclePhaseStart = now; chargeCycleCharging = true; return true
        }
        let elapsed = now.timeIntervalSince(start)
        if chargeCycleCharging {
            if elapsed >= onTime { chargeCycleCharging = false; chargeCyclePhaseStart = now; return false }
            return true
        } else {
            if elapsed >= offTime { chargeCycleCharging = true; chargeCyclePhaseStart = now; return true }
            return false
        }
    }

    /// Ready-by top-up: on a scheduled day, within the estimated lead time before
    /// the target and still below the target level → charge past the limit so the
    /// battery reaches the target right around the target time (minimizing hours
    /// spent pinned at a high charge). Lead time is estimated from how far below
    /// the target we are, since `timeToFull` isn't available while holding.
    private func topUpBypassActive(_ cfg: BattlifyConfig, level: Int, now: Date) -> Bool {
        let r = cfg.readyBy
        guard r.enabled, r.days.contains(now), level < r.targetPercent else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard nowMin <= r.targetMinute else { return false }   // target already passed today
        let minutesUntil = r.targetMinute - nowMin
        // ~1.5 min per percentage point to charge, plus a 15-minute safety buffer.
        let minutesNeeded = Double(r.targetPercent - level) * 1.5 + 15
        return Double(minutesUntil) <= minutesNeeded
    }

    /// "Always Active": keep the Mac fully awake with the lid closed so terminal
    /// jobs and background tasks keep running. Enforced only on AC power — closed
    /// and unventilated, a Mac kept awake on battery would drain fast and heat up,
    /// so unplugging auto-releases it. Combines `pmset disablesleep` (the only
    /// thing that prevents lid-close/clamshell sleep) with a PreventSystemSleep
    /// assertion as a belt-and-suspenders against idle sleep. Because disablesleep
    /// doesn't survive a reboot, the first tick after startup re-applies it
    /// (`lastDisableSleep` starts nil, forcing a write).
    private func updateKeepAwake(_ cfg: BattlifyConfig, _ snap: BatterySnapshot) {
        var want = cfg.keepAwake && snap.isPluggedIn

        // Task-gated: only hold while a matching task is actually running, so the
        // Mac sleeps once the work finishes instead of staying awake forever.
        if want && cfg.keepAwakeRequiresTask {
            want = ProcessScan.isBusy(names: cfg.keepAwakeProcesses, minCpu: cfg.keepAwakeMinCpu)
        }
        // Thermal guardrail: a closed, unventilated Mac running hard can overheat,
        // so release keep-awake (allow sleep) once it crosses the limit.
        if want, cfg.keepAwakeMaxTempC > 0, let t = snap.temperature, t >= cfg.keepAwakeMaxTempC {
            want = false
            log("keep-awake released: temperature \(String(format: "%.1f", t))°C ≥ guardrail \(cfg.keepAwakeMaxTempC)°C")
        }

        if lastDisableSleep != want {
            if PowerSettings.setDisableSleep(want) {
                lastDisableSleep = want
                log("keep-awake (disablesleep) \(want ? "enabled" : "disabled")")
            }
        }

        if want && keepAwakeAssertion == 0 {
            var id: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Battlify: keep awake (Always Active)" as CFString,
                &id)
            if ok == kIOReturnSuccess { keepAwakeAssertion = id }
        } else if !want && keepAwakeAssertion != 0 {
            IOPMAssertionRelease(keepAwakeAssertion)
            keepAwakeAssertion = 0
        }
    }

    /// Hold an idle-sleep assertion only while it's useful: prevent-idle-sleep on,
    /// a limit being enforced, and running on wall power (so we never keep the Mac
    /// awake — and draining — on battery). Released as soon as any of those drop.
    private func updateIdleSleepAssertion(_ cfg: BattlifyConfig, _ snap: BatterySnapshot) {
        let want = cfg.preventIdleSleep && cfg.chargeLimitEnabled && snap.isPluggedIn
        if want && idleSleepAssertion == 0 {
            var id: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Battlify: enforcing charge limit" as CFString,
                &id)
            if ok == kIOReturnSuccess { idleSleepAssertion = id; log("idle-sleep assertion held") }
        } else if !want && idleSleepAssertion != 0 {
            IOPMAssertionRelease(idleSleepAssertion)
            idleSleepAssertion = 0
            log("idle-sleep assertion released")
        }
    }

    /// Force-discharge to bring the level down to the limit when plugged in above
    /// it; otherwise keep the adapter on. Always leaves the adapter enabled when
    /// not actively sailing down, so the Mac charges normally.
    private func manageDischarge(_ cfg: BattlifyConfig, _ snap: BatterySnapshot,
                                 scheduleDischarge: Bool) {
        guard charge.isAdapterControlSupported else { return }

        // Discharge-to-limit (when you plug in above the limit) …
        let limitDischarge = cfg.dischargeEnabled
            && cfg.chargeLimitEnabled
            && !cfg.calibrateToFull   // calibration is charging up, don't fight it
            && snap.percentage > cfg.chargeLimit
        // … or an active "run on battery" schedule window.
        let shouldDischarge = snap.isPluggedIn && (limitDischarge || scheduleDischarge)

        let adapterOn = (try? charge.isAdapterEnabled()) ?? true
        if shouldDischarge {
            if adapterOn { try? charge.disableAdapter(); log("discharging to limit") }
        } else if !adapterOn {
            try? charge.enableAdapter(); log("adapter restored")
        }
    }

    /// Drive the MagSafe LED per the configured mode:
    ///   - `.system`: hand control back to macOS.
    ///   - `.off`: force the LED off.
    ///   - `.status`: orange charging, green holding at the limit, off while
    ///     settling after wake, and system when unplugged.
    /// Only writes the SMC when the actual LED differs from the target.
    private func updateMagSafeLED(_ cfg: BattlifyConfig, _ snap: BatterySnapshot,
                                  charging desired: Bool, settling: Bool) {
        guard charge.isMagSafeSupported else { return }

        let target: MagSafeLED
        switch cfg.magSafeLedMode {
        case .system:
            // Hand control back to macOS once, then leave it alone.
            if let last = lastLed, last != .system {
                try? charge.setMagSafeLED(.system)
                lastLed = .system
            }
            return
        case .off:
            target = .off
        case .status:
            if settling { target = .off }               // waiting after wake
            else if !snap.isPluggedIn { target = .system }
            else if desired { target = .orange }        // charging
            else { target = .green }                    // holding at the limit
        }

        // Re-assert if the actual LED drifted (macOS re-manages it) or changed —
        // don't rely on a cache, or a stopped charge won't turn the light green.
        if charge.magSafeLED() != target {
            try? charge.setMagSafeLED(target)
        }
        lastLed = target
    }

    private func recordHistoryIfDue(_ snap: BatterySnapshot) {
        ticksSinceSample += 1
        guard ticksSinceSample >= ticksPerSample else { return }
        ticksSinceSample = 0

        HistoryStore.append(BatterySample(
            t: Date(), pct: snap.percentage,
            charging: snap.isCharging, temp: snap.temperature))
        HistoryStore.trim()
    }

    private func ensure(enabled desired: Bool, current: Bool) {
        if current == desired { return }
        do {
            if desired { try charge.enableCharging() } else { try charge.disableCharging() }
            log("charging \(desired ? "enabled" : "disabled")")
        } catch {
            log("error setting charging=\(desired): \(error)")
        }
    }

    // MARK: - Signals & logging

    private func installSignalHandlers() {
        // Handle SIGTERM/SIGINT via DispatchSource rather than a C signal handler:
        // the cleanup forks `pmset`, opens/writes the SMC and allocates — none of
        // which is safe in an async-signal context (it could deadlock on malloc or
        // corrupt the SMC layer, defeating the very safety this cleanup provides).
        // The source's handler runs as an ordinary block on `signalQueue`, so it's
        // all safe, and it takes `lock` to serialize with the tick loop's SMC use.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)   // ignore default disposition; the source owns it
            let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            src.setEventHandler { self.performCleanupAndExit() }
            src.resume()
            signalSources.append(src)
        }
    }

    /// Restore a safe state and exit: re-enable charging, restore the adapter and
    /// hand the MagSafe LED back to macOS, and clear `disablesleep` so keep-awake
    /// never outlives the daemon. Serialized with the tick loop via `lock`.
    private func performCleanupAndExit() -> Never {
        lock.lock()   // hold through exit; serialize SMC access with tick()
        PowerSettings.setDisableSleep(false)
        try? charge.enableCharging()
        if charge.isAdapterControlSupported { try? charge.enableAdapter() }
        if charge.isMagSafeSupported { try? charge.setMagSafeLED(.system) }
        exit(0)
    }

    private func log(_ m: String) {
        FileHandle.standardError.write(Data("battlify-helper: \(m)\n".utf8))
    }
    private func err(_ m: String) {
        FileHandle.standardError.write(Data("battlify-helper: error: \(m)\n".utf8))
    }
}
