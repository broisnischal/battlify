import Foundation
import Combine
import BattlifyKit

/// "Endurance" battery-saver mode. Layers the biggest real drain levers:
///   - caps screen brightness (the single largest lever),
///   - turns on macOS Low Power Mode (via the daemon),
///   - disables battery-wasteful background wake (Power Nap / wake-on-network / TCP keep-alive),
///   - turns Bluetooth off.
/// It snapshots the prior state on activation and restores it on exit, so nothing is
/// left changed. A measured drain meter (discharge watts, averaged per mode) proves
/// the effect — the exact % is workload-dependent, so we show what's actually measured.
@MainActor
final class EnduranceStore: ObservableObject {
    @Published private(set) var active = false
    /// Auto-activate whenever running on battery.
    @Published var autoOnBattery: Bool { didSet { defaults.set(autoOnBattery, forKey: Keys.auto) } }
    /// Brightness cap applied while active (0…1).
    @Published var brightnessCap: Double {
        didSet {
            defaults.set(brightnessCap, forKey: Keys.cap)
            if active { BrightnessControl.set(Float(brightnessCap)) }   // re-apply live
        }
    }

    /// Live discharge (watts); 0 when charging/plugged.
    @Published private(set) var liveWatts: Double = 0
    /// Rolling-average discharge watts measured with the mode OFF / ON.
    @Published private(set) var normalWatts: Double?
    @Published private(set) var enduranceWatts: Double?

    /// Measured reduction (%) once both averages exist, else nil.
    var savingsPercent: Int? {
        guard let n = normalWatts, let e = enduranceWatts, n > 0.1 else { return nil }
        return max(0, Int((( n - e) / n * 100).rounded()))
    }

    var brightnessSupported: Bool { BrightnessControl.isSupported }

    private weak var chargeLimit: ChargeLimitStore?
    private var timer: Timer?
    private var autoActivated = false

    // Saved state to restore on exit.
    private var savedBrightness: Float?
    private var savedBluetooth: Bool?
    private var savedToggles: [PowerToggle: Bool] = [:]

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let auto = "endurance.autoOnBattery"
        static let cap = "endurance.brightnessCap"
        static let normal = "endurance.normalWatts"
        static let endur = "endurance.enduranceWatts"
    }
    // EMA weight for new drain samples; low so a spiky workload doesn't swing it.
    private let emaAlpha = 0.2

    init() {
        autoOnBattery = defaults.object(forKey: Keys.auto) as? Bool ?? true
        brightnessCap = defaults.object(forKey: Keys.cap) as? Double ?? 0.40
        normalWatts = defaults.object(forKey: Keys.normal) as? Double
        enduranceWatts = defaults.object(forKey: Keys.endur) as? Double
    }

    /// Wire up the daemon command channel and start the sampling loop (call once).
    func start(chargeLimit: ChargeLimitStore) {
        self.chargeLimit = chargeLimit
        guard timer == nil else { return }
        tick()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// User (or auto) flips the mode.
    func setActive(_ on: Bool, auto: Bool = false) {
        if !auto { autoActivated = false }
        guard on != active else { return }
        active = on
        if on { apply() } else { restore() }
    }

    func toggle() { setActive(!active) }

    // MARK: - Apply / restore

    private func apply() {
        savedBrightness = BrightnessControl.current()
        BrightnessControl.set(Float(brightnessCap))

        chargeLimit?.setLowPowerMode(true)

        // Snapshot the three background-wake toggles, then turn them off.
        let toggles = chargeLimit?.powerToggles ?? [:]
        for t in [PowerToggle.powerNap, .wakeOnNetwork, .tcpKeepAlive] {
            savedToggles[t] = toggles[t.rawValue] ?? true
            chargeLimit?.setPowerToggle(t, false)
        }

        savedBluetooth = RadioControl.isBluetoothOn
        if savedBluetooth == true { RadioControl.setBluetooth(false) }
    }

    private func restore() {
        if let b = savedBrightness { BrightnessControl.set(b); savedBrightness = nil }
        chargeLimit?.setLowPowerMode(false)
        for (t, was) in savedToggles { chargeLimit?.setPowerToggle(t, was) }
        savedToggles.removeAll()
        if savedBluetooth == true { RadioControl.setBluetooth(true) }
        savedBluetooth = nil
    }

    // MARK: - Sampling / auto

    private func tick() {
        let snap = BatteryMonitor.read()
        let flow = PowerMonitor.read()
        let onBattery = !snap.onExternalPower

        // Auto activate/deactivate on plug state.
        if autoOnBattery {
            if onBattery && !active {
                setActive(true, auto: true); autoActivated = true
            } else if !onBattery && active && autoActivated {
                setActive(false, auto: true); autoActivated = false
            }
        }

        // Drain measurement (only meaningful while discharging).
        let watts = flow.dischargeWatts
        liveWatts = onBattery ? watts : 0
        guard onBattery, watts > 0.5 else { return }
        if active {
            enduranceWatts = ema(enduranceWatts, watts)
            defaults.set(enduranceWatts, forKey: Keys.endur)
        } else {
            normalWatts = ema(normalWatts, watts)
            defaults.set(normalWatts, forKey: Keys.normal)
        }
    }

    private func ema(_ prev: Double?, _ sample: Double) -> Double {
        guard let prev else { return sample }
        return prev * (1 - emaAlpha) + sample * emaAlpha
    }
}
