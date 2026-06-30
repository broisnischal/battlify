import Foundation
import Combine
import BattPieKit

/// User preferences + behavior for lid-close radio automation. These run as the
/// user, so they live in UserDefaults (not the root config).
@MainActor
final class AutomationStore: ObservableObject {
    @Published var wifiOffOnLidClose: Bool {
        didSet { defaults.set(wifiOffOnLidClose, forKey: Keys.wifi) }
    }
    @Published var bluetoothOffOnLidClose: Bool {
        didSet { defaults.set(bluetoothOffOnLidClose, forKey: Keys.bt) }
    }
    @Published var restoreOnWake: Bool {
        didSet { defaults.set(restoreOnWake, forKey: Keys.restore) }
    }

    private let defaults = UserDefaults.standard
    private let lid = LidMonitor()

    // Radio states captured at sleep, to restore on wake.
    private var wifiWasOn = false
    private var bluetoothWasOn = false

    private enum Keys {
        static let wifi = "automation.wifiOffOnLidClose"
        static let bt = "automation.bluetoothOffOnLidClose"
        static let restore = "automation.restoreOnWake"
    }

    init() {
        wifiOffOnLidClose = defaults.bool(forKey: Keys.wifi)
        bluetoothOffOnLidClose = defaults.bool(forKey: Keys.bt)
        // Default restore-on-wake to true on first run.
        restoreOnWake = defaults.object(forKey: Keys.restore) as? Bool ?? true

        lid.onWillSleep = { [weak self] clamshellClosed in
            // LidMonitor callback arrives on the main run loop.
            MainActor.assumeIsolated { self?.handleLidClose(clamshellClosed) }
        }
        lid.onDidWake = { [weak self] in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        lid.start()
    }

    /// Apply the lid-radio parts of a save mode's profile.
    func apply(_ profile: SaveProfile) {
        wifiOffOnLidClose = profile.wifiOffOnLidClose
        bluetoothOffOnLidClose = profile.bluetoothOffOnLidClose
        restoreOnWake = profile.restoreOnWake
    }

    private func handleLidClose(_ clamshellClosed: Bool) {
        guard clamshellClosed else { return } // ignore non-lid sleeps

        if wifiOffOnLidClose {
            wifiWasOn = RadioControl.isWiFiOn
            if wifiWasOn { RadioControl.setWiFi(false) }
        }
        if bluetoothOffOnLidClose {
            bluetoothWasOn = RadioControl.isBluetoothOn
            if bluetoothWasOn { RadioControl.setBluetooth(false) }
        }
    }

    private func handleWake() {
        guard restoreOnWake else { return }
        if wifiOffOnLidClose && wifiWasOn { RadioControl.setWiFi(true) }
        if bluetoothOffOnLidClose && bluetoothWasOn { RadioControl.setBluetooth(true) }
    }
}
