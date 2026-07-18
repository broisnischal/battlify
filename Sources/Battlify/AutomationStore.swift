import Foundation
import Combine
import AppKit
import BattlifyKit

/// Lid-close radio automation. Runs as the user, so preferences live in UserDefaults, not the root config.
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
    /// Lid close applies maximum power saving (Low Power Mode, wake-ups off, radios off); restored on open.
    @Published var superSaveOnLidClose: Bool {
        didSet { defaults.set(superSaveOnLidClose, forKey: Keys.superSave) }
    }

    @Published private(set) var isLidClosed = false
    @Published private(set) var externalDisplayCount = 0

    /// Lid shut but the Mac is awake (docked to an external display on power).
    var isClamshellMode: Bool { isLidClosed }

    @Published private(set) var lastLidSession: LidSession?

    private let defaults = UserDefaults.standard
    private let lid = LidMonitor()
    private var lidPollTimer: Timer?

    // Radio states captured at sleep, to restore on wake.
    private var wifiWasOn = false
    private var bluetoothWasOn = false

    // Snapshot of the exact power state deep save changes (LPM + sleep/wake toggles),
    // restored verbatim on wake so the user's charge config is never touched.
    private var savedLowPowerMode: Bool?
    private var savedPowerToggles: [String: Bool]?
    private var deepSaveActive = false

    /// The sleep/wake power toggles deep save turns off (and restores on wake).
    private static let deepSaveToggles: [PowerToggle] = [.powerNap, .wakeOnNetwork, .tcpKeepAlive]

    private enum Keys {
        static let wifi = "automation.wifiOffOnLidClose"
        static let bt = "automation.bluetoothOffOnLidClose"
        static let restore = "automation.restoreOnWake"
        static let superSave = "automation.superSaveOnLidClose"
        // Pending lid session (persisted so it survives the sleep).
        static let pendingCloseAt = "lidsession.closedAt"
        static let pendingCloseCharge = "lidsession.closeCharge"
    }

    init() {
        wifiOffOnLidClose = defaults.bool(forKey: Keys.wifi)
        bluetoothOffOnLidClose = defaults.bool(forKey: Keys.bt)
        restoreOnWake = defaults.object(forKey: Keys.restore) as? Bool ?? true
        superSaveOnLidClose = defaults.bool(forKey: Keys.superSave)
        lastLidSession = LidSessionStore.recent(limit: 1).first

        lid.onWillSleep = { [weak self] clamshellClosed in
            // assumeIsolated traps on macOS 26 when the IOKit callback isn't on the main actor's executor.
            Task { @MainActor in self?.handleWillSleep(clamshellClosed) }
        }
        lid.onDidWake = { [weak self] in
            Task { @MainActor in self?.handleWake() }
        }
        lid.start()

        pollLidState()
        // Lid state changes are rare and reads are cheap — poll slowly to save CPU.
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollLidState() }
        }
        t.tolerance = 5   // lid state also updates on sleep/wake; slack is fine
        RunLoop.main.add(t, forMode: .common)
        lidPollTimer = t
    }

    private func pollLidState() {
        isLidClosed = LidMonitor.isClamshellClosed()
        // NSScreen import via AppKit; count displays beyond the built-in.
        externalDisplayCount = max(0, NSScreen.screens.count - (isLidClosed ? 0 : 1))
    }

    /// Apply only the lid-radio parts of a save mode's profile.
    func apply(_ profile: SaveProfile) {
        wifiOffOnLidClose = profile.wifiOffOnLidClose
        bluetoothOffOnLidClose = profile.bluetoothOffOnLidClose
        restoreOnWake = profile.restoreOnWake
    }

    /// Runs just before any sleep; synchronous so it finishes before the system powers down.
    private func handleWillSleep(_ clamshellClosed: Bool) {
        // Daemon decides based on its config, so this is a cheap no-op when disabled.
        _ = try? ControlClient.send(.prepareForSleep)
        handleLidClose(clamshellClosed)
    }

    private func handleLidClose(_ clamshellClosed: Bool) {
        guard clamshellClosed else { return }

        // Record the charge at close so we can measure the drop on wake.
        defaults.set(Date(), forKey: Keys.pendingCloseAt)
        defaults.set(BatteryMonitor.read().percentage, forKey: Keys.pendingCloseCharge)

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
        pollLidState()        // reflect "lid open" immediately
        completeLidSession()

        if deepSaveActive {
            // Restore only what deep save changed (LPM + toggles); re-applying a SaveMode
            // would clobber the user's charge config. Nil snapshot = never captured, so skip.
            if let lpm = savedLowPowerMode {
                _ = try? ControlClient.send(.setLowPowerMode(lpm))
            }
            if let toggles = savedPowerToggles {
                for toggle in Self.deepSaveToggles {
                    if let on = toggles[toggle.rawValue] {
                        _ = try? ControlClient.send(.setPowerToggle(toggle, on))
                    }
                }
            }
            savedLowPowerMode = nil
            savedPowerToggles = nil
            deepSaveActive = false
            restoreRadios()
        } else if restoreOnWake {
            restoreRadios()
        }
    }

    private func completeLidSession() {
        guard let closedAt = defaults.object(forKey: Keys.pendingCloseAt) as? Date else { return }
        let closeCharge = defaults.integer(forKey: Keys.pendingCloseCharge)
        defaults.removeObject(forKey: Keys.pendingCloseAt)
        defaults.removeObject(forKey: Keys.pendingCloseCharge)

        let openCharge = BatteryMonitor.read().percentage
        let session = LidSession(closedAt: closedAt, closeCharge: closeCharge,
                                 openedAt: Date(), openCharge: openCharge)
        // Skip blips shorter than a minute.
        guard session.duration >= 60 else { return }
        LidSessionStore.append(session)
        lastLidSession = session
    }

    /// macOS is slow to ready Wi-Fi/Bluetooth right after wake, so wait briefly and retry.
    private func restoreRadios() {
        let wantWifi = wifiWasOn
        let wantBT = bluetoothWasOn
        guard wantWifi || wantBT else { return }

        func attempt(_ n: Int) {
            if wantWifi && !RadioControl.isWiFiOn { RadioControl.setWiFi(true) }
            if wantBT && !RadioControl.isBluetoothOn { RadioControl.setBluetooth(true) }
            let wifiOK = !wantWifi || RadioControl.isWiFiOn
            let btOK = !wantBT || RadioControl.isBluetoothOn
            if (!wifiOK || !btOK) && n < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { attempt(n + 1) }
            } else {
                self.wifiWasOn = false
                self.bluetoothWasOn = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { attempt(0) }
    }

    // MARK: - Deep save (sleepwatcher-style)

    /// Synchronous so it finishes before the system is allowed to sleep.
    private func enterDeepSave() {
        // Snapshot the exact state we change, to restore verbatim on wake without touching charge config.
        if let status = try? ControlClient.send(.getStatus) {
            savedLowPowerMode = status.lowPowerModeEnabled
            savedPowerToggles = status.powerToggles
        }
        // Radios off (works even without the daemon).
        wifiWasOn = RadioControl.isWiFiOn
        if wifiWasOn { RadioControl.setWiFi(false) }
        bluetoothWasOn = RadioControl.isBluetoothOn
        if bluetoothWasOn { RadioControl.setBluetooth(false) }

        _ = try? ControlClient.send(.setLowPowerMode(true))
        _ = try? ControlClient.send(.setPowerToggle(.powerNap, false))
        _ = try? ControlClient.send(.setPowerToggle(.wakeOnNetwork, false))
        _ = try? ControlClient.send(.setPowerToggle(.tcpKeepAlive, false))
        deepSaveActive = true
    }
}
