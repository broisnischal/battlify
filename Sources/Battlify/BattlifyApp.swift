import SwiftUI
import AppKit
import BattlifyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app-switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct BattlifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var battery = BatteryStore()
    @StateObject private var chargeLimit = ChargeLimitStore()
    @StateObject private var automation = AutomationStore()
    @StateObject private var processes = ProcessMonitor()
    @StateObject private var license = LicenseManager()
    @StateObject private var startup = StartupManager()
    @StateObject private var updater = UpdaterManager()
    @StateObject private var actions = SystemActions()
    @StateObject private var caffeine = CaffeineManager()
    @StateObject private var settings = AppSettings()
    @StateObject private var notifier = NotificationManager()
    @StateObject private var network = NetworkProfileStore()
    @StateObject private var endurance = EnduranceStore()
    @StateObject private var triggers = TriggerStore()
    @StateObject private var hotkeys = HotkeyStore()
    @StateObject private var restReminder = RestReminder()
    @StateObject private var overlay = ChargeOverlayController()
    @StateObject private var idleSaver = IdleSaverStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(battery)
                .environmentObject(chargeLimit)
                .environmentObject(automation)
                .environmentObject(processes)
                .environmentObject(license)
                .environmentObject(startup)
                .environmentObject(updater)
                .environmentObject(actions)
                .environmentObject(caffeine)
                .environmentObject(settings)
                .environmentObject(notifier)
                .environmentObject(network)
                .environmentObject(endurance)
                .environmentObject(triggers)
                .environmentObject(hotkeys)
                .environmentObject(restReminder)
                .environmentObject(idleSaver)
                .environmentObject(overlay)
                .onAppear {
                    network.chargeLimit = chargeLimit
                    automation.chargeLimit = chargeLimit
                    endurance.start(chargeLimit: chargeLimit)
                }
        } label: {
            // Its own observing view so it re-renders reliably — a label closure that
            // reads the store inline can render once and go stale. It also renders at
            // launch, which is where the automation rules get started (the dropdown's
            // `onAppear` wouldn't run until you first opened the menu).
            MenuBarLabel(battery: battery, chargeLimit: chargeLimit,
                         settings: settings, notifier: notifier, triggers: triggers,
                         hotkeys: hotkeys, caffeine: caffeine, actions: actions,
                         license: license, restReminder: restReminder, overlay: overlay,
                         endurance: endurance, idleSaver: idleSaver)
        }
        .menuBarExtraStyle(.window)

        // Set-once controls live here so the menu dropdown stays focused on daily use.
        Window("Battlify Settings", id: "settings") {
            SettingsView()
                .environmentObject(battery)
                .environmentObject(chargeLimit)
                .environmentObject(automation)
                .environmentObject(caffeine)
                .environmentObject(license)
                .environmentObject(startup)
                .environmentObject(updater)
                .environmentObject(settings)
                .environmentObject(notifier)
                .environmentObject(network)
                .environmentObject(endurance)
                .environmentObject(triggers)
                .environmentObject(hotkeys)
                .environmentObject(overlay)
                .environmentObject(idleSaver)
        }
        .windowResizability(.contentSize)

        Window("Battery Details", id: "details") {
            DetailsView()
                .environmentObject(battery)
                .environmentObject(processes)
                .environmentObject(chargeLimit)
                .environmentObject(automation)
        }
        .windowResizability(.contentSize)

        Window("Battery History", id: "history") {
            HistoryView()
        }
        .windowResizability(.contentSize)

        Window("Activate Battlify", id: "license") {
            LicenseView()
                .environmentObject(license)
        }
        .windowResizability(.contentSize)
    }
}

/// Its own View with @ObservedObject stores so SwiftUI re-renders on snapshot/charge
/// changes — a MenuBarExtra label closure reading a store inline can go stale/blank.
struct MenuBarLabel: View {
    @ObservedObject var battery: BatteryStore
    @ObservedObject var chargeLimit: ChargeLimitStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var notifier: NotificationManager
    let triggers: TriggerStore
    // Not observed: the label doesn't render from these. They're here because the
    // label is the one view that exists from launch, which is where global shortcuts
    // have to start listening — waiting for the dropdown's first open would mean the
    // shortcuts silently didn't work until you'd clicked the menu bar once. The rest
    // reminder and Caffeine's power policy start from here for the same reason.
    let hotkeys: HotkeyStore
    let caffeine: CaffeineManager
    let actions: SystemActions
    let license: LicenseManager
    let restReminder: RestReminder
    let overlay: ChargeOverlayController
    let endurance: EnduranceStore
    let idleSaver: IdleSaverStore
    @Environment(\.openWindow) private var openWindow

    /// Animation tick for the menu-bar glyph. Only runs while an animation is visible —
    /// never while discharging (a battery saver shouldn't burn cycles on battery).
    @State private var animFrame = 0
    @State private var celebrating = false
    @State private var celebrateTicks = 0
    /// When charging last stopped — to tell "just finished" from arriving full via wake.
    @State private var chargeStoppedAt: Date?
    /// A one-off connect/disconnect animation, and how far through it we are.
    @State private var transition: IconTransition?
    @State private var transitionStep = 0

    var body: some View {
        let snap = battery.snapshot
        // One source of truth for motion: the system's Reduce Motion, unless the user has
        // overridden it for this app. Read here so every animation below agrees.
        let motion = settings.motionAllowed
        let celebratingNow = celebrating && motion
        // Success flash is green only when coloring is on; mono blinks by alpha instead.
        let tint: MenuBarTint =
            celebratingNow && settings.colorMenuBarIcon ? .colored(.systemGreen)
            : settings.colorMenuBarIcon ? tint(for: snap) : .neutral
        // Each tick re-renders the status item, and that relayout measured ~10% of a
        // core sustained — the entire time the Mac was plugged in. So the charging
        // animation is opt-in. The completion flash still runs when it fires: it's
        // bounded to about three seconds, not the whole charge.
        let animating = motion
            && (celebrating
                || (settings.animateMenuBarIcon
                    && (snap.isCharging || settings.batteryIconStyle.animatesOnBattery)))
        // The label renders at launch — a reliable hook to start notification detection.
        notifier.startIfNeeded(settings: settings, battery: battery, chargeLimit: chargeLimit)
        // Same reason, and it has to be here rather than in `onAppear`: a status-item
        // label's `onAppear` doesn't fire at launch, so registering shortcuts there
        // left every one of them dead until the menu had been opened. `attach` is
        // idempotent, so calling it on each body evaluation costs nothing.
        hotkeys.attach(chargeLimit: chargeLimit, caffeine: caffeine,
                       systemActions: actions, endurance: endurance,
                       idleSaver: idleSaver, settings: settings, license: license,
                       openWindow: { id in
                           NSApplication.shared.activate(ignoringOtherApps: true)
                           openWindow(id: id)
                       })
        // The label re-renders on every snapshot change, which is exactly when Caffeine's
        // power policy needs re-evaluating (unplugging must stop it holding the screen
        // awake and draining). The call is idempotent, so re-sending costs nothing.
        caffeine.applyPolicy(keepDisplayOnBattery: settings.caffeineKeepDisplayOnBattery,
                             endOnBattery: settings.caffeineEndOnBattery,
                             onExternalPower: snap.onExternalPower)
        restReminder.startIfNeeded(settings: settings, battery: battery)
        idleSaver.startIfNeeded()
        return HStack(spacing: 2) {
            // Drawn as an NSImage: SwiftUI's .foregroundStyle is overridden for status-item
            // labels, and the renderer draws the charging bolt inside the glyph.
            Image(nsImage: BatteryIconRenderer.image(
                style: settings.batteryIconStyle,
                percentage: snap.percentage,
                charging: snap.isCharging,
                tint: tint,
                frame: animFrame,
                celebrating: celebratingNow,
                transition: transition,
                transitionStep: transitionStep))
            if let text = labelText(snap) {
                // Monospaced digits so the item doesn't shift width as it ticks.
                Text(text).monospacedDigit()
            }
        }
        .help(helpText(snap))
        // One shared tick; task(id:) cancels it when nothing animates. 250ms — twice the
        // rate of the old 500ms, because a six-step sweep at 2fps reads as a slideshow no
        // matter how it's eased. It only runs while plugged in with animation opted into,
        // and stops the moment nothing needs it.
        .task(id: animating) {
            guard animating else { animFrame = 0; return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                animFrame &+= 1
                if celebrating {
                    celebrateTicks += 1
                    if celebrateTicks >= 12 {   // ~3 s at 250ms, as before
                        celebrating = false
                        celebrateTicks = 0
                    }
                }
            }
        }
        // The transition runs on its own clock: the shared 500ms tick is far too slow to
        // read as a morph, and this only lasts about half a second.
        .task(id: transition) {
            guard transition != nil else { transitionStep = 0; return }
            for step in 0..<BatteryIconRenderer.transitionSteps {
                transitionStep = step
                try? await Task.sleep(
                    nanoseconds: UInt64(BatteryIconRenderer.transitionStepDuration * 1_000_000_000))
                if Task.isCancelled { return }
            }
            transition = nil
            transitionStep = 0
        }
        // Record when charging stops, *before* the completion check below reads it.
        .onChange(of: snap.isCharging) { old, new in
            if old && !new { chargeStoppedAt = Date() }
        }
        // Flash only when it lands full/at-limit right after charging, not on wake-already-holding.
        .onChange(of: chargeComplete(snap)) { _, done in
            let justCharged = snap.isCharging
                || (chargeStoppedAt.map { Date().timeIntervalSince($0) < 120 } ?? false)
            guard done, justCharged else { return }
            if settings.hapticsEnabled { HapticFeedback.limitReached() }
            guard settings.motionAllowed else { return }
            celebrating = true
            celebrateTicks = 0
        }
        // Plug and unplug feedback. Driven off the snapshot rather than a power-source
        // callback of its own: this view already re-renders on every snapshot change, and
        // `onChange` fires once per real transition rather than on every poll.
        .onChange(of: snap.isPluggedIn) { was, isNow in
            guard was != isNow else { return }
            if settings.hapticsEnabled {
                isNow ? HapticFeedback.chargeConnected() : HapticFeedback.chargeDisconnected()
            }
            // The glyph itself reacts: the bolt grows out of a flat spark on connect and
            // collapses back into one on unplug, so the menu bar tells you what changed
            // even with no overlay and no sound.
            if settings.motionAllowed {
                transitionStep = 0
                transition = isNow ? .connected : .disconnected
            }
            guard settings.chargeOverlayEnabled,
                  isNow || settings.chargeOverlayOnUnplug else { return }
            overlay.show(style: settings.chargeOverlayStyle,
                         duration: settings.chargeOverlayDuration,
                         percentage: snap.percentage,
                         plugging: isNow,
                         allowMotion: settings.motionAllowed)
        }
        // The status item exists from launch, so this is where the automation
        // rules start watching — they must run whether or not the menu is opened.
        .onAppear { triggers.attach(chargeLimit: chargeLimit, battery: battery) }
    }

    /// Truly full, or held at the user's charge limit.
    private func chargeComplete(_ snap: BatterySnapshot) -> Bool {
        snap.isFullyCharged
            || (chargeLimit.limitEnabled && !chargeLimit.chargingEnabled
                && chargeLimit.pauseReason == "limit")
    }

    /// Red when warm or critically low, green charging, otherwise neutral.
    private func tint(for snap: BatterySnapshot) -> MenuBarTint {
        if isWarm(snap) { return .colored(.systemRed) }
        if snap.percentage <= 20 && !snap.isPluggedIn { return .colored(.systemRed) }
        if snap.isCharging { return .colored(.systemGreen) }
        return .neutral
    }

    /// Held for heat, or genuinely hot (≥40 °C) even with heat-pause off.
    private func isWarm(_ snap: BatterySnapshot) -> Bool {
        if chargeLimit.pauseReason == "heat" { return true }
        if let t = snap.temperature, t >= 40 { return true }
        return false
    }

    /// Text beside the icon, per the display preference. Time-remaining falls back
    /// to the percentage when macOS has no estimate (right after a plug change, or
    /// while holding at the limit) rather than blanking out.
    private func labelText(_ snap: BatterySnapshot) -> String? {
        let mode = settings.menuBarDisplay
        let pct = mode.showsPercentage ? "\(snap.percentage)%" : nil
        let time = mode.showsTime ? remainingText(snap) : nil
        switch (pct, time) {
        case let (p?, t?):  return "\(p) · \(t)"
        case let (p?, nil): return p
        case let (nil, t?): return t
        case (nil, nil):    return mode.showsTime ? "\(snap.percentage)%" : nil
        }
    }

    /// "1:25" — time to full while charging, time to empty on battery. Nil when
    /// macOS hasn't got an estimate (it reports −1 while recalculating, which
    /// `BatteryMonitor` already drops).
    private func remainingText(_ snap: BatterySnapshot) -> String? {
        let minutes = snap.isCharging ? snap.timeToFull : snap.timeToEmpty
        guard let minutes, minutes > 0 else { return nil }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    private func helpText(_ snap: BatterySnapshot) -> String {
        if !chargeLimit.chargingEnabled, let reason = chargeLimit.pauseReason {
            switch reason {
            case "limit":    return "Holding at \(chargeLimit.limit)% limit"
            case "heat":     return "Charging paused — battery warm"
            case "settling": return "Settling after wake"
            case "paused":   return "Charging paused"
            case "sleep":    return "Charging cut for sleep"
            default: break
            }
        }
        if snap.isCharging  { return "Charging — \(snap.percentage)%" }
        if snap.isPluggedIn { return "Plugged in — \(snap.percentage)%" }
        return "On battery — \(snap.percentage)%"
    }

}

enum MenuBarTint {
    case neutral            // adaptive monochrome (template)
    case colored(NSColor)

    var isNeutral: Bool {
        if case .neutral = self { return true }
        return false
    }

    var cacheKey: String {
        switch self {
        case .neutral: return "neutral"
        case .colored(let c): return "colored(\(c))"
        }
    }
}

extension BatterySnapshot {
    /// SF Symbol for the charge level. Bolt drawn separately — SF Symbols only ships
    /// a bolt variant for the full battery.
    var menuBarSymbol: String {
        switch percentage {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }

    /// Green charging, red when critically low, otherwise neutral.
    var menuBarTint: MenuBarTint {
        if isCharging { return .colored(.systemGreen) }
        if percentage <= 20 && !isPluggedIn { return .colored(.systemRed) }
        return .neutral
    }
}
