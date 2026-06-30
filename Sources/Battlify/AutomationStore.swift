import Foundation
import Combine
import AppKit
import BattlifyKit

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

    /// Live lid sensor (clamshell) state, polled while the Mac is awake.
    @Published private(set) var isLidClosed = false
    /// Number of external displays currently attached.
    @Published private(set) var externalDisplayCount = 0

    /// "Clamshell mode": lid shut but the Mac is awake — i.e. docked to an
    /// external display on power. A prime battery-aging scenario.
    var isClamshellMode: Bool { isLidClosed }

    private let defaults = UserDefaults.standard
    private let lid = LidMonitor()
    private var lidPollTimer: Timer?

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

        pollLidState()
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollLidState() }
        }
        RunLoop.main.add(t, forMode: .common)
        lidPollTimer = t
    }

    private func pollLidState() {
        isLidClosed = LidMonitor.isClamshellClosed()
        // NSScreen import via AppKit; count displays beyond the built-in.
        externalDisplayCount = max(0, NSScreen.screens.count - (isLidClosed ? 0 : 1))
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
