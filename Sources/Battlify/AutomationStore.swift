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
    /// When on, closing the lid applies maximum power saving (Low Power Mode,
    /// all sleep wake-ups off, radios off) and opening it restores your prior
    /// state. Like sleepwatcher, driven by the IOKit sleep/wake events.
    @Published var superSaveOnLidClose: Bool {
        didSet { defaults.set(superSaveOnLidClose, forKey: Keys.superSave) }
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

    // Mode to restore to on wake when super-save-on-lid-close fired.
    private var savedMode: SaveMode?
    private var deepSaveActive = false

    private enum Keys {
        static let wifi = "automation.wifiOffOnLidClose"
        static let bt = "automation.bluetoothOffOnLidClose"
        static let restore = "automation.restoreOnWake"
        static let superSave = "automation.superSaveOnLidClose"
    }

    init() {
        wifiOffOnLidClose = defaults.bool(forKey: Keys.wifi)
        bluetoothOffOnLidClose = defaults.bool(forKey: Keys.bt)
        // Default restore-on-wake to true on first run.
        restoreOnWake = defaults.object(forKey: Keys.restore) as? Bool ?? true
        superSaveOnLidClose = defaults.bool(forKey: Keys.superSave)

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

        if superSaveOnLidClose {
            enterDeepSave()
        } else {
            if wifiOffOnLidClose {
                wifiWasOn = RadioControl.isWiFiOn
                if wifiWasOn { RadioControl.setWiFi(false) }
            }
            if bluetoothOffOnLidClose {
                bluetoothWasOn = RadioControl.isBluetoothOn
                if bluetoothWasOn { RadioControl.setBluetooth(false) }
            }
        }
    }

    private func handleWake() {
        if deepSaveActive {
            exitDeepSave()
            return
        }
        guard restoreOnWake else { return }
        if wifiOffOnLidClose && wifiWasOn { RadioControl.setWiFi(true) }
        if bluetoothOffOnLidClose && bluetoothWasOn { RadioControl.setBluetooth(true) }
    }

    // MARK: - Deep save (sleepwatcher-style)

    /// Maximize savings as the lid closes. Calls are synchronous so they finish
    /// before the system is allowed to sleep.
    private func enterDeepSave() {
        // Remember the current mode so we can restore it on wake.
        if let status = try? ControlClient.send(.getStatus) {
            savedMode = status.config.mode
        }
        // Radios off (works even without the daemon).
        wifiWasOn = RadioControl.isWiFiOn
        if wifiWasOn { RadioControl.setWiFi(false) }
        bluetoothWasOn = RadioControl.isBluetoothOn
        if bluetoothWasOn { RadioControl.setBluetooth(false) }

        // Maximum savings via the root daemon.
        _ = try? ControlClient.send(.setLowPowerMode(true))
        _ = try? ControlClient.send(.setPowerToggle(.powerNap, false))
        _ = try? ControlClient.send(.setPowerToggle(.wakeOnNetwork, false))
        _ = try? ControlClient.send(.setPowerToggle(.tcpKeepAlive, false))
        deepSaveActive = true
    }

    /// Restore the pre-close state when the lid opens again.
    private func exitDeepSave() {
        // Re-apply the previous save mode (resets Low Power Mode + sleep wake-ups
        // to that profile). Falls back to Off if we never captured one.
        _ = try? ControlClient.send(.applyMode(savedMode ?? .off))
        savedMode = nil
        deepSaveActive = false

        if wifiWasOn { RadioControl.setWiFi(true) }
        if bluetoothWasOn { RadioControl.setBluetooth(true) }
    }
}
