import Foundation
import BattPieKit

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
            Thread.sleep(forTimeInterval: 10)
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
            cfg.resumeMargin = min(20, max(1, cfg.resumeMargin))
            do {
                try ConfigStore.save(cfg)
                tick() // apply immediately
                return status(ok: true, message: "saved")
            } catch {
                return status(ok: false, message: "save failed: \(error)")
            }

        case .setLowPowerMode(let on):
            let ok = LowPowerMode.set(on)
            return status(ok: ok, message: ok ? "lowpowermode set" : "pmset failed")

        case .setPowerToggle(let toggle, let on):
            let ok = PowerSettings.set(toggle, on)
            return status(ok: ok, message: ok ? "\(toggle.rawValue) set" : "pmset failed")

        case .applyMode(let mode):
            return applyMode(mode)
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

        tick() // enforce charge limit immediately
        return status(ok: true, message: "mode \(mode.rawValue)")
    }

    private func status(ok: Bool, message: String? = nil) -> ControlResponse {
        let snap = BatteryMonitor.read()
        return ControlResponse(
            ok: ok,
            config: ConfigStore.load(),
            batteryPercent: snap.percentage,
            chargingEnabled: (try? charge.isChargingEnabled()) ?? false,
            schemeDescription: charge.schemeDescription,
            lowPowerModeEnabled: LowPowerMode.isEnabled(),
            powerToggles: PowerSettings.readToggles(),
            pauseReason: lastPauseReason,
            message: message
        )
    }

    private static func failureResponse() -> ControlResponse {
        ControlResponse(ok: false, config: .default, batteryPercent: 0,
                        chargingEnabled: false, schemeDescription: "n/a",
                        lowPowerModeEnabled: false, powerToggles: [:],
                        pauseReason: nil, message: "daemon unavailable")
    }

    // MARK: - Enforcement (caller holds lock)

    private func tick() {
        let cfg = ConfigStore.load()
        let snap = BatteryMonitor.read()
        let level = snap.percentage

        recordHistoryIfDue(snap)

        let charging = (try? charge.isChargingEnabled()) ?? true
        var desired = true
        var reason: String? = nil

        // Charge-limit constraint, with a hysteresis band so we don't toggle at
        // the exact threshold.
        if cfg.chargeLimitEnabled {
            if level >= cfg.chargeLimit {
                desired = false; reason = "limit"
            } else if level >= cfg.chargeLimit - cfg.resumeMargin && !charging {
                desired = false; reason = "limit"   // hold paused inside the band
            }
        }

        // Heat constraint: only matters while we'd otherwise charge. Pause when at
        // or above the max temp; stay paused (for heat) until it cools past the band.
        if desired, cfg.heatAwareEnabled, let t = snap.temperature {
            if t >= cfg.maxChargeTempC {
                desired = false; reason = "heat"
            } else if t >= cfg.maxChargeTempC - heatResumeMargin
                        && !charging && lastPauseReason == "heat" {
                desired = false; reason = "heat"
            }
        }

        lastPauseReason = desired ? nil : reason
        ensure(enabled: desired)
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

    private func ensure(enabled desired: Bool) {
        guard let current = try? charge.isChargingEnabled() else { return }
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
        // Re-enable charging on exit so we never strand the machine.
        let cleanup: @convention(c) (Int32) -> Void = { _ in
            let smc = SMC()
            if (try? smc.open()) != nil {
                try? ChargeController(smc: smc).enableCharging()
                smc.close()
            }
            exit(0)
        }
        signal(SIGTERM, cleanup)
        signal(SIGINT, cleanup)
    }

    private func log(_ m: String) {
        FileHandle.standardError.write(Data("battpie-helper: \(m)\n".utf8))
    }
    private func err(_ m: String) {
        FileHandle.standardError.write(Data("battpie-helper: error: \(m)\n".utf8))
    }
}
