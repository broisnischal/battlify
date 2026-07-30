import Foundation
import IOKit
import IOKit.pwr_mgt
import BattlifyKit

/// Enforcement loop plus control server: holds the configured charge limit.
///
/// Safety: SIGTERM/SIGINT re-enables charging so the Mac is never left unable to
/// charge. SMC access is serialized with `lock` (tick loop and connection handler
/// both touch it); `@unchecked Sendable` is sound because mutable state is only
/// reached under `lock`.
final class Daemon: @unchecked Sendable {
    private let smc = SMC()
    private let charge: ChargeController
    private let lock = NSLock()

    // History sampling. Timed rather than counted in ticks, because the tick rate
    // itself varies (see `nextInterval`) and the graph's spacing shouldn't.
    private var lastSampleAt: Date?
    private let sampleInterval = 300.0   // ~5 min between history points

    // Why charging is currently paused ("limit"/"heat"/nil), for status reporting.
    private var lastPauseReason: String?
    // Charge-limit hysteresis, tracked explicitly rather than inferred from the raw
    // SMC charging flag — duty-cycling (Charge Power < 100) also toggles that flag,
    // and reading it back would latch the "hold at limit" branch during a rest phase,
    // stalling charging inside the band. Set at/above the limit, cleared below
    // (limit − resumeMargin); charging is held while true.
    private var holdingAtLimit = false
    // °C below maxChargeTempC at which heat-paused charging may resume.
    private let heatResumeMargin = 2.0
    // Have we ever read a battery temperature? Used to fail safe: if the sensor has
    // worked before but a read fails while heat-aware is on, we pause charging rather
    // than silently charge uncapped. Macs that never expose a temp sensor stay unblocked.
    private var sawTemperature = false
    // Last MagSafe LED we set, so we only write the SMC on change.
    private var lastLed: MagSafeLED?

    // Post-wake settle: a tick gap ≫ interval implies we slept; hold charging + LED off briefly.
    private var lastTickAt: Date?
    private var settleUntil: Date?
    /// What the run loop waits after the current tick; `nextInterval` sets it from
    /// `TickPolicy`, which is where the reasoning about cadence lives.
    private var tickInterval = TickPolicy.active
    private var wakeSettleDuration: Double { 15.0 }   // how long to settle after wake

    // DispatchSource fires cleanup on this queue in a normal context, not an async-signal handler.
    private let signalQueue = DispatchQueue(label: "com.battlify.helper.signals")
    private var signalSources: [DispatchSourceSignal] = []

    // Held IOPMAssertion preventing idle sleep (0 = none held).
    private var idleSleepAssertion: IOPMAssertionID = 0

    // "Always Active" state; nil disablesleep = not yet written, so we pmset only on change.
    private var keepAwakeAssertion: IOPMAssertionID = 0
    private var lastDisableSleep: Bool?
    // Force display off once per lid-closed spell while keep-awake holds; resets when the lid opens.
    private var displayForcedOffWhileClosed = false

    // Auto-sleep-when-task-done state. We only sleep once we've actually seen the
    // matching task running (so enabling the option while idle doesn't sleep), and
    // only after it's been gone for a few ticks (so a brief gap between a build's
    // sub-processes doesn't sleep prematurely).
    private var keepAwakeSawTask = false
    private var keepAwakeTaskIdleTicks = 0
    private let sleepAfterTaskIdleTicks = 3   // ~30s gone before we sleep

    // Charge-power duty cycle in long phases (≥ minChargeDwell) to avoid flicker/hardware thrash.
    private let minChargeDwell: TimeInterval = 120   // ≥ 2 min per phase
    private var chargeCycleCharging = true
    private var chargeCyclePhaseStart: Date?

    // Cache pmset-derived state briefly (each read forks pmset); invalidated when we change it.
    private var pmsetCacheAt: Date?
    private var pmsetCacheLPM = false
    private var pmsetCacheToggles: [String: Bool] = [:]
    // Longer than the GUI's 30s status poll so periodic refreshes hit the cache
    // instead of forking two `pmset` each time; we invalidate on any change we make.
    private let pmsetCacheTTL: TimeInterval = 60

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
            let wait = tickInterval
            lock.unlock()
            Thread.sleep(forTimeInterval: wait)
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
            // wide recharge band (≤40%) but keep the floor (limit − margin) ≥ 20%
            cfg.resumeMargin = max(1, min(cfg.resumeMargin, 40, cfg.chargeLimit - 20))
            do {
                try ConfigStore.save(cfg)
                tick() // apply immediately
                // System-wide and persistent, so only write it when it differs.
                if PowerSettings.readHibernateMode() != cfg.sleepDepth.hibernateMode,
                   !PowerSettings.setSleepDepth(cfg.sleepDepth) {
                    return status(ok: false, message: "saved, but pmset refused hibernatemode")
                }
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
            // Cut charging before sleep so macOS can't top up while the daemon is
            // frozen; the SMC inhibit persists through sleep, re-evaluated on wake.
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
            // GUI can't delete the root-owned history file; restart the sampling clock
            // so a cleared graph doesn't immediately re-append mid-tick.
            HistoryStore.clear()
            lastSampleAt = Date()
            return status(ok: true, message: "history cleared")
        }
    }

    /// Apply the daemon-controlled parts of a save mode; the GUI applies lid-radio prefs separately.
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

    /// pmset-derived state, cached for `pmsetCacheTTL` to avoid forking pmset on every status call.
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
        var snap = BatteryMonitor.read()
        let level = snap.percentage
        let now = Date()

        // Prefer raw SMC AC-W for adapter presence: it survives force-discharge (OS
        // flips to "battery"), keeping onExternalPower-gated decisions stable while draining.
        if let ac = charge.isACPresent() { snap.isExternalConnected = ac }

        recordHistoryIfDue(snap, now: now)

        // Detect wake: a tick gap much larger than the interval we asked for means the
        // clock ran on without us, i.e. we were frozen. Scaled off the interval in
        // force, so backing off to a slow tick doesn't read as a wake every time.
        if let last = lastTickAt, now.timeIntervalSince(last) > tickInterval * 3 {
            settleUntil = now.addingTimeInterval(wakeSettleDuration)
            log("woke from sleep; settling for \(Int(wakeSettleDuration))s")
        }
        lastTickAt = now

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
        // active schedule window (first match wins) + ready-by top-up; both feed the decision below
        let activeSchedule = cfg.schedules.first { $0.isActive(at: now) }
        let topUp = topUpBypassActive(cfg, level: level, now: now)
        var desired = true
        var reason: String? = nil

        if paused {
            // pause overrides everything
            desired = false; reason = "paused"
        } else if settling {
            desired = false; reason = "settling"
        } else if let s = activeSchedule, s.action == .hold || s.action == .discharge {
            // hold/discharge window keeps charging off (discharge itself is driven in manageDischarge)
            desired = false; reason = "schedule"
        } else {
            // charge windows, ready-by top-up, and calibration all bypass the limit ceiling
            let bypassLimit = cfg.calibrateToFull || topUp || (activeSchedule?.action == .charge)

            // Hysteresis band, tracked via `holdingAtLimit` (not the raw SMC flag, which
            // duty-cycling toggles): hold once we reach the limit, and keep holding while
            // coasting down through the band until we drop below (limit − resumeMargin),
            // then resume charging back up to the limit.
            if cfg.chargeLimitEnabled && !bypassLimit {
                if level >= cfg.chargeLimit {
                    holdingAtLimit = true
                } else if level < cfg.chargeLimit - cfg.resumeMargin {
                    holdingAtLimit = false
                }
                if holdingAtLimit { desired = false; reason = "limit" }
            } else {
                holdingAtLimit = false   // not enforcing the ceiling right now
            }
            // heat constraint, only while we'd otherwise charge
            if desired, cfg.heatAwareEnabled {
                if let t = snap.temperature {
                    sawTemperature = true
                    if t >= cfg.maxChargeTempC {
                        desired = false; reason = "heat"
                    } else if t >= cfg.maxChargeTempC - heatResumeMargin
                                && !charging && lastPauseReason == "heat" {
                        desired = false; reason = "heat"
                    }
                } else if sawTemperature {
                    // Sensor worked before but this read failed: fail safe (pause)
                    // rather than charge with the thermal cap silently disabled.
                    desired = false; reason = "heat"
                    if lastPauseReason != "heat" {
                        log("heat-aware: temperature unreadable; pausing charging as a precaution")
                    }
                }
            }
        }

        // Duty-cycle to the requested power; the LED follows the steady regime, not each phase, to avoid flicker.
        let enable = chargeDutyGate(desired: desired, power: cfg.chargePower, now: now)
        let chargingRegime = desired && cfg.chargePower > 0

        lastPauseReason = desired ? (enable ? nil : "slow") : reason
        ensure(enabled: enable, current: charging)
        manageDischarge(cfg, snap, scheduleDischarge: activeSchedule?.action == .discharge)
        updateMagSafeLED(cfg, snap, charging: chargingRegime, settling: settling)
        updateIdleSleepAssertion(cfg, snap)
        updateKeepAwake(cfg, snap)
        tickInterval = nextInterval(cfg, snap)
    }

    /// How long to wait before the next tick (see `TickPolicy`). The clamshell read is
    /// skipped unless the config could actually allow a back-off, so the common case
    /// costs nothing.
    private func nextInterval(_ cfg: BattlifyConfig, _ snap: BatterySnapshot) -> Double {
        guard TickPolicy.hasNothingToManage(cfg, onExternalPower: snap.onExternalPower)
        else { return TickPolicy.active }
        return TickPolicy.interval(cfg, onExternalPower: snap.onExternalPower,
                                   lidClosed: SystemPower.isClamshellClosed())
    }

    /// Whether to charge this tick for the requested power (0–100%): 100% passes
    /// through, below 100% duty-cycles in long phases (≥ `minChargeDwell`) to avoid flicker.
    private func chargeDutyGate(desired: Bool, power: Int, now: Date) -> Bool {
        // reset when not charging so it resumes promptly in a fresh charge phase
        guard desired else {
            chargeCyclePhaseStart = nil; chargeCycleCharging = true; return false
        }
        let p = min(100, max(0, power))
        if p >= 100 { chargeCyclePhaseStart = nil; chargeCycleCharging = true; return true }
        if p <= 0  { chargeCyclePhaseStart = nil; chargeCycleCharging = false; return false }

        // minority phase gets the 2-min floor; majority is stretched to hit the ratio (both ≥ 2 min)
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

    /// Ready-by top-up: charge past the limit within the estimated lead time so the
    /// battery hits the target right around the target time. Lead time is estimated
    /// from the gap to target (`timeToFull` is unavailable while holding).
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

    /// "Always Active": keep the Mac awake with the lid closed. `pmset disablesleep`
    /// is the only thing that prevents clamshell sleep, paired with a PreventSystemSleep
    /// assertion for idle sleep. It doesn't survive a reboot, so the first tick re-applies
    /// it (`lastDisableSleep` starts nil).
    private func updateKeepAwake(_ cfg: BattlifyConfig, _ snap: BatterySnapshot) {
        // AC by default (onExternalPower survives force-discharge but releases on a real
        // unplug); keepAwakeOnBattery opts out, guarded by the thermal limit below.
        var want = cfg.keepAwake && (cfg.keepAwakeOnBattery || snap.onExternalPower)

        // Task-gated: only hold while a matching task runs, so the Mac sleeps when work finishes.
        let taskGated = want && cfg.keepAwakeRequiresTask
        // `ps` is the expensive part of the tick, so only scan when task-gating needs it.
        let scan = taskGated
            ? ProcessScan.scan(names: cfg.keepAwakeProcesses)
            : ProcessScan.Reading()
        let taskBusy = taskGated
            && (scan.matchedName || (cfg.keepAwakeMinCpu > 0 && scan.topCPU >= cfg.keepAwakeMinCpu))
        if taskGated { want = taskBusy }
        // Thermal guardrail: release keep-awake once a closed Mac crosses the temp limit.
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

        // Lid shut + awake: force the display off (keyboard backlight follows) once per
        // close; nothing can wake it. Reset when the lid opens or keep-awake stops holding.
        let lidClosed = want && SystemPower.isClamshellClosed()
        if lidClosed {
            if !displayForcedOffWhileClosed {
                PowerSettings.displaySleepNow()
                displayForcedOffWhileClosed = true
                log("keep-awake: lid closed, display + keyboard backlight off")
            }
        } else {
            displayForcedOffWhileClosed = false
        }

        // Auto-sleep once the monitored task finishes. `want`/the hold above are
        // already released when the task isn't busy, so `pmset sleepnow` isn't
        // blocked by our own disablesleep. Debounced so a brief gap between a
        // build's sub-processes doesn't sleep mid-job, and only after we've seen
        // the task actually run this session.
        if taskGated {
            if taskBusy {
                keepAwakeSawTask = true
                keepAwakeTaskIdleTicks = 0
            } else if keepAwakeSawTask {
                keepAwakeTaskIdleTicks += 1
                if cfg.sleepWhenTaskDone && keepAwakeTaskIdleTicks >= sleepAfterTaskIdleTicks {
                    log("keep-awake task finished — sleeping now")
                    keepAwakeSawTask = false
                    keepAwakeTaskIdleTicks = 0
                    PowerSettings.sleepNow()
                }
            }
        } else {
            keepAwakeSawTask = false
            keepAwakeTaskIdleTicks = 0
        }
    }

    /// Hold an idle-sleep assertion only while prevent-idle-sleep is on, a limit is
    /// enforced, and on wall power (never keep draining on battery).
    private func updateIdleSleepAssertion(_ cfg: BattlifyConfig, _ snap: BatterySnapshot) {
        // onExternalPower (not isPluggedIn) so a force-discharge doesn't drop the
        // assertion and let the daemon freeze mid-drain.
        let want = cfg.preventIdleSleep && cfg.chargeLimitEnabled && snap.onExternalPower
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

    /// Force-discharge down to the limit when plugged in above it; otherwise keep the adapter on.
    private func manageDischarge(_ cfg: BattlifyConfig, _ snap: BatterySnapshot,
                                 scheduleDischarge: Bool) {
        guard charge.isAdapterControlSupported else { return }

        let limitDischarge = cfg.dischargeEnabled
            && cfg.chargeLimitEnabled
            && !cfg.calibrateToFull   // calibration is charging up, don't fight it
            && snap.percentage > cfg.chargeLimit
        // Gate on onExternalPower, NOT isPluggedIn: cutting the adapter makes macOS report
        // "Battery Power", so isPluggedIn would flip false next tick and we'd restore the
        // adapter — oscillating instead of draining. onExternalPower stays true while the cable is in.
        let shouldDischarge = snap.onExternalPower && (limitDischarge || scheduleDischarge)

        let adapterOn = (try? charge.isAdapterEnabled()) ?? true
        if shouldDischarge {
            if adapterOn { try? charge.disableAdapter(); log("discharging to limit") }
        } else if !adapterOn {
            try? charge.enableAdapter(); log("adapter restored")
        }
    }

    /// Drive the MagSafe LED per mode; only writes the SMC when the actual LED differs from the target.
    private func updateMagSafeLED(_ cfg: BattlifyConfig, _ snap: BatterySnapshot,
                                  charging desired: Bool, settling: Bool) {
        guard charge.isMagSafeSupported else { return }

        let target: MagSafeLED
        switch cfg.magSafeLedMode {
        case .system:
            // hand control back to macOS once, then leave it alone
            if let last = lastLed, last != .system {
                try? charge.setMagSafeLED(.system)
                lastLed = .system
            }
            return
        case .off:
            target = .off
        case .status:
            if settling { target = .off }               // waiting after wake
            else if !snap.onExternalPower { target = .system }  // truly unplugged
            else if desired { target = .orange }        // charging
            else { target = .green }                    // holding / discharging to limit
        }

        // Re-assert on drift (macOS re-manages the LED); a cache would miss it and leave the light wrong.
        if charge.magSafeLED() != target {
            try? charge.setMagSafeLED(target)
        }
        lastLed = target
    }

    private func recordHistoryIfDue(_ snap: BatterySnapshot, now: Date) {
        if let last = lastSampleAt, now.timeIntervalSince(last) < sampleInterval { return }
        lastSampleAt = now

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
        // DispatchSource, not a C signal handler: cleanup forks pmset, writes the SMC
        // and allocates — none async-signal-safe. The source's handler runs as an
        // ordinary block on signalQueue and takes `lock` to serialize with the tick loop.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)   // ignore default disposition; the source owns it
            let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            src.setEventHandler { self.performCleanupAndExit() }
            src.resume()
            signalSources.append(src)
        }
    }

    /// Restore a safe state and exit: preserve the charge limit across shutdown,
    /// restore the adapter, hand the LED to macOS, clear disablesleep. Serialized
    /// with the tick loop via `lock`.
    ///
    /// launchd sends SIGTERM on every shutdown/restart, so this runs then. The SMC
    /// charge-inhibit key persists while the Mac is powered off but plugged in (the
    /// same property `prepareForSleep` relies on), so if we cleared it here the
    /// battery would charge straight past the limit — to full — while the Mac is
    /// off. So when limiting is on we leave the inhibit *set*; only when limiting is
    /// off do we re-enable charging, to never leave a Mac unable to charge.
    /// (Uninstall re-enables explicitly, after unloading this daemon.)
    private func performCleanupAndExit() -> Never {
        lock.lock()   // hold through exit; serialize SMC access with tick()
        PowerSettings.setDisableSleep(false)
        if ConfigStore.load().chargeLimitEnabled {
            try? charge.disableCharging()
        } else {
            try? charge.enableCharging()
        }
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
