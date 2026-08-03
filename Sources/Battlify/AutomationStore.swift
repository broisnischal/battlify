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

    /// Read to know whether "Always Active" is actually holding the Mac awake.
    weak var chargeLimit: ChargeLimitStore?

    private let defaults = UserDefaults.standard
    private let lid = LidMonitor()
    private var lidPollTimer: Timer?
    private var clamshellSaverTimer: Timer?

    // Radio states captured at sleep, to restore on wake.
    private var wifiWasOn = false
    private var bluetoothWasOn = false

    // Snapshot of the exact power state deep save changes (LPM + sleep/wake toggles),
    // restored verbatim on wake so the user's charge config is never touched.
    private var savedLowPowerMode: Bool?
    private var savedPowerToggles: [String: Bool]?
    private var deepSaveActive = false

    /// The sleep/wake power toggles deep save turns off (and restores on wake).
    // Everything deep save switches off, and therefore everything it snapshots and
    // puts back on wake. `proximityWake` and `ttysKeepAwake` matter most of all: the
    // first wakes the Mac every time a nearby iPhone stirs, and the second stops it
    // sleeping at all while a terminal session is open — the two reasons a closed Mac
    // comes out of a bag warm and empty.
    private static let deepSaveToggles: [PowerToggle] =
        [.powerNap, .wakeOnNetwork, .tcpKeepAlive, .proximityWake, .ttysKeepAwake]

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
        let closed = LidMonitor.isClamshellClosed()
        // NSScreen import via AppKit; count displays beyond the built-in.
        let externals = max(0, NSScreen.screens.count - (closed ? 0 : 1))
        // Both are unchanged on almost every poll; publishing anyway would relayout
        // the menu bar item four times a minute for nothing.
        if closed != isLidClosed { isLidClosed = closed }
        if externals != externalDisplayCount { externalDisplayCount = externals }
        updateClamshellSaver()
    }

    // MARK: - Clamshell display saver

    // With "Always Active" holding the Mac awake, closing the lid skips macOS's normal
    // clamshell display-off, so the internal panel + keyboard backlight stay lit (and
    // hot) inside the shut lid. Re-issue a forced display sleep while the lid is shut so
    // a wake can't leave it on; the keyboard backlight follows display sleep. Never runs
    // with an external display attached (that would blank the user's monitor).
    private func updateClamshellSaver() {
        if shouldSaveClamshell() { startClamshellSaver() } else { stopClamshellSaver() }
    }

    private func shouldSaveClamshell() -> Bool {
        guard let cl = chargeLimit, cl.keepAwake else { return false }
        guard SystemPower.isClamshellClosed(), !Self.hasExternalDisplay() else { return false }
        return cl.keepAwakeOnBattery || BatteryMonitor.read().onExternalPower
    }

    private func startClamshellSaver() {
        guard clamshellSaverTimer == nil else { return }
        forceInternalDisplayOff()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.clamshellSaverTick() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        clamshellSaverTimer = t
    }

    private func clamshellSaverTick() {
        // Re-read live so opening the lid or attaching a display stops us within one tick.
        guard shouldSaveClamshell() else { stopClamshellSaver(); return }
        forceInternalDisplayOff()
    }

    private func stopClamshellSaver() {
        clamshellSaverTimer?.invalidate()
        clamshellSaverTimer = nil
    }

    private func forceInternalDisplayOff() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
    }

    /// True if any non-built-in display is online — then we must not force display sleep.
    private static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
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
        // Drive the same list we snapshot, so nothing can be switched off here and
        // then forgotten on wake.
        for toggle in Self.deepSaveToggles {
            _ = try? ControlClient.send(.setPowerToggle(toggle, false))
        }
        deepSaveActive = true
    }
}
