import Foundation
import Combine
import AppKit
import BattlifyKit

/// "Rest the Mac without closing the lid."
///
/// Closing the lid is the usual way to make a Mac stop spending power: the screen and the
/// keyboard backlight go out and the machine quiesces. This does the same thing with the
/// lid open — either on request, or once you've been away long enough — and puts back
/// exactly what it changed when you come back.
///
/// What it can and can't touch, so the Settings copy can be honest:
///   - Display: `pmset displaysleepnow`, the same call the clamshell saver uses. The
///     keyboard backlight follows the display, so there's nothing separate to switch.
///   - Low Power Mode: through the root daemon, snapshotted first and restored on wake.
///   - Wi-Fi and Bluetooth: optional, off by default — losing the network while a
///     download or a call is running would be worse than the power it saves.
///   - Fans: nothing to do. Apple silicon refuses SMC fan writes; the fans wind down on
///     their own once the machine is idle, which is the point of resting it.
@MainActor
final class IdleSaverStore: ObservableObject {
    /// Rest automatically once the Mac has been idle for `afterMinutes`.
    @Published var autoEnabled: Bool {
        didSet { defaults.set(autoEnabled, forKey: Keys.auto); reschedule() }
    }
    /// Idle minutes before resting. 30 by default: long enough that a pause to read
    /// isn't mistaken for leaving.
    @Published var afterMinutes: Int {
        didSet { defaults.set(afterMinutes, forKey: Keys.after) }
    }
    /// Also drop to Low Power Mode while resting.
    @Published var lowPowerWhileResting: Bool {
        didSet { defaults.set(lowPowerWhileResting, forKey: Keys.lpm) }
    }
    /// Also switch the radios off. Off by default.
    @Published var radiosOffWhileResting: Bool {
        didSet { defaults.set(radiosOffWhileResting, forKey: Keys.radios) }
    }
    /// Minutes of resting after which the Mac sleeps outright. 0 = stay awake, screen off.
    @Published var sleepAfterMinutes: Int {
        didSet { defaults.set(sleepAfterMinutes, forKey: Keys.sleepAfter) }
    }

    @Published private(set) var resting = false
    /// When resting began, for the menu's "resting since…" line.
    @Published private(set) var restingSince: Date?

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let auto = "idleSaver.auto"
        static let after = "idleSaver.afterMinutes"
        static let lpm = "idleSaver.lowPower"
        static let radios = "idleSaver.radios"
        static let sleepAfter = "idleSaver.sleepAfterMinutes"
    }

    /// What we changed, so waking restores it rather than imposing a default.
    private var savedLowPowerMode: Bool?
    private var savedWiFi: Bool?
    private var savedBluetooth: Bool?

    private var timer: Timer?
    private var started = false

    init() {
        autoEnabled = defaults.bool(forKey: Keys.auto)
        let storedAfter = defaults.integer(forKey: Keys.after)
        afterMinutes = storedAfter > 0 ? storedAfter : 30
        lowPowerWhileResting = defaults.object(forKey: Keys.lpm) as? Bool ?? true
        radiosOffWhileResting = defaults.bool(forKey: Keys.radios)
        sleepAfterMinutes = defaults.integer(forKey: Keys.sleepAfter)
    }

    /// Idempotent; called from the always-rendered menu-bar label.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        reschedule()
    }

    // MARK: - Manual control

    /// Rest now, whatever the idle time. The screen goes out immediately.
    func restNow() {
        guard !resting else { return }
        beginResting()
    }

    /// Stop resting and put everything back. Any input already woke the display; this is
    /// about the things macOS won't undo for us.
    func wake() {
        guard resting else { return }
        endResting()
    }

    // MARK: - Idle watching

    /// Seconds since the last keyboard, mouse or trackpad event. `hidSystemState` covers
    /// the whole session rather than this process, which is the difference between "the
    /// user is away" and "the user isn't using Battlify".
    static func idleSeconds() -> TimeInterval {
        // kCGAnyInputEventType — not exposed to Swift as a named case.
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        // Runs while watching for idleness *or* while resting — resting needs the timer even
        // with the automatic trigger off, because that's what notices you're back.
        guard autoEnabled || resting else { return }
        // Two cadences, for two jobs. Waiting for a 30-minute threshold needs no better than
        // a minute's resolution, and a fast timer for that in an app whose job is saving
        // power would be absurd. Coming *back* is different: the display has already woken on
        // the keypress, so anything still held — Low Power Mode, the radios — has to be put
        // back promptly or the Mac feels throttled after you've returned to it.
        let interval: TimeInterval = resting ? 2 : 60
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = resting ? 0.5 : 15
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        let idle = Self.idleSeconds()

        if resting {
            // The click or keystroke that started resting is itself activity — pressing
            // ⌃⌥⌘R leaves idle at zero — so without this the first poll would wake it
            // straight back up. Four seconds is longer than two polls and shorter than
            // anyone's patience.
            if let since = restingSince, Date().timeIntervalSince(since) < 4 { return }
            // After that, any input at all means they're back: the display has already woken
            // on the keypress, so whatever is still held has to be put back with it. The
            // threshold sits just above the 2s poll — long enough that the poll can't race a
            // genuine wake, short enough to land within a couple of seconds of the keypress.
            if idle < 3 { endResting(); return }
            if sleepAfterMinutes > 0, let since = restingSince,
               Date().timeIntervalSince(since) >= Double(sleepAfterMinutes) * 60 {
                sleepNow()
            }
            return
        }

        guard autoEnabled, idle >= Double(afterMinutes) * 60 else { return }
        // Never rest a Mac that's mid-presentation: an external display usually means
        // someone is looking at something.
        guard !Self.hasExternalDisplay() else { return }
        beginResting()
    }

    // MARK: - Applying / restoring

    private func beginResting() {
        resting = true
        restingSince = Date()
        reschedule()   // switch to the fast poll that notices you coming back

        if lowPowerWhileResting {
            if let status = try? ControlClient.send(.getStatus) {
                savedLowPowerMode = status.lowPowerModeEnabled
            }
            _ = try? ControlClient.send(.setLowPowerMode(true))
        }
        if radiosOffWhileResting {
            savedWiFi = RadioControl.isWiFiOn
            if savedWiFi == true { _ = RadioControl.setWiFi(false) }
            savedBluetooth = RadioControl.isBluetoothOn
            if savedBluetooth == true { RadioControl.setBluetooth(false) }
        }
        // Display last: everything above takes a moment, and doing it after the screen is
        // already dark would mean the work happens while the user thinks it's resting.
        displayOff()
    }

    private func endResting() {
        resting = false
        restingSince = nil
        reschedule()   // back to the slow idle watch (or no timer, if that's off)

        if let previous = savedLowPowerMode {
            _ = try? ControlClient.send(.setLowPowerMode(previous))
            savedLowPowerMode = nil
        }
        // Radios come back only if we were the ones who switched them off.
        if savedWiFi == true, !RadioControl.isWiFiOn { _ = RadioControl.setWiFi(true) }
        if savedBluetooth == true, !RadioControl.isBluetoothOn { RadioControl.setBluetooth(true) }
        savedWiFi = nil
        savedBluetooth = nil
    }

    private func displayOff() { run("/usr/bin/pmset", ["displaysleepnow"]) }
    private func sleepNow() { run("/usr/bin/pmset", ["sleepnow"]) }

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
    }

    /// True if any non-built-in display is online.
    private static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}
