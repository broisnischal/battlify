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
                .onAppear { network.chargeLimit = chargeLimit }
        } label: {
            // Kept in its own observing view (below) so it re-renders reliably
            // when the snapshot changes — a label closure that reads the store
            // directly can render once and go stale.
            MenuBarLabel(battery: battery, chargeLimit: chargeLimit,
                         settings: settings, notifier: notifier)
        }
        .menuBarExtraStyle(.window)

        // Detached preferences window — everything set-once lives here so the
        // menu-bar dropdown stays focused on day-to-day controls.
        Window("Battlify Settings", id: "settings") {
            SettingsView()
                .environmentObject(battery)
                .environmentObject(chargeLimit)
                .environmentObject(automation)
                .environmentObject(license)
                .environmentObject(startup)
                .environmentObject(updater)
                .environmentObject(settings)
                .environmentObject(notifier)
                .environmentObject(network)
        }
        .windowResizability(.contentSize)

        // Detached window: battery stats + health tips + top energy users.
        Window("Battery Details", id: "details") {
            DetailsView()
                .environmentObject(battery)
                .environmentObject(processes)
                .environmentObject(chargeLimit)
                .environmentObject(automation)
        }
        .windowResizability(.contentSize)

        // Detached window for the history charts.
        Window("Battery History", id: "history") {
            HistoryView()
        }
        .windowResizability(.contentSize)

        // License / activation window.
        Window("Activate Battlify", id: "license") {
            LicenseView()
                .environmentObject(license)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar label. Its own `View` with `@ObservedObject` stores so SwiftUI
/// re-renders it whenever the battery snapshot or charge state changes (a
/// `MenuBarExtra` label closure that reads a store inline is prone to going
/// stale / blank).
struct MenuBarLabel: View {
    @ObservedObject var battery: BatteryStore
    @ObservedObject var chargeLimit: ChargeLimitStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var notifier: NotificationManager

    /// Animation tick for the menu-bar glyph: the pixel style's charging sweep,
    /// the other styles' bolt pulse, and the charge-complete flash. The driving
    /// task only exists while one of those is actually visible — we deliberately
    /// never animate while discharging (a battery saver shouldn't spend cycles
    /// when you're on battery), and Reduce Motion turns all of it off.
    @State private var animFrame = 0
    /// Charge-complete "success" flash in progress (a few green blinks).
    @State private var celebrating = false
    @State private var celebrateTicks = 0
    /// When charging last stopped — used to tell "charging just finished" apart
    /// from unrelated ways of arriving at the holding/full state (e.g. wake).
    @State private var chargeStoppedAt: Date?

    var body: some View {
        let snap = battery.snapshot
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let celebratingNow = celebrating && !reduceMotion
        // Respect the "color icon by state" preference; otherwise stay neutral.
        // The success flash goes green only when coloring is allowed — with a
        // monochrome icon it blinks by alpha instead (the renderer handles that).
        let tint: MenuBarTint =
            celebratingNow && settings.colorMenuBarIcon ? .colored(.systemGreen)
            : settings.colorMenuBarIcon ? tint(for: snap) : .neutral
        let animating = !reduceMotion && (snap.isCharging || celebrating)
        // The label renders at launch, so this is a reliable one-shot hook to wire
        // up notification detection (which then runs via Combine, not view lifecycle).
        notifier.startIfNeeded(settings: settings, battery: battery, chargeLimit: chargeLimit)
        return HStack(spacing: 2) {
            // Battery glyph in the user's chosen style, drawn as an NSImage whose
            // fill tracks the exact percentage (so the level changes smoothly, not
            // in coarse steps) and whose colour actually shows in the menu bar —
            // SwiftUI's `.foregroundStyle` is overridden there by the template
            // treatment for status-item labels. The charging bolt is drawn inside
            // the glyph by the renderer, so there's no separate bolt image.
            Image(nsImage: BatteryIconRenderer.image(
                style: settings.batteryIconStyle,
                percentage: snap.percentage,
                charging: snap.isCharging,
                tint: tint,
                frame: animFrame,
                celebrating: celebratingNow))
            if settings.showMenuBarPercentage {
                Text("\(snap.percentage)%")
            }
        }
        .help(helpText(snap))
        // One shared ~0.5 s tick drives whichever animation is visible; task(id:)
        // cancels it the moment nothing animates and restarts it when needed.
        .task(id: animating) {
            guard animating else { animFrame = 0; return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                animFrame &+= 1
                if celebrating {
                    celebrateTicks += 1
                    if celebrateTicks >= 6 {   // ~3 s: three full blinks
                        celebrating = false
                        celebrateTicks = 0
                    }
                }
            }
        }
        // Record when charging stops, *before* the completion check below reads it.
        .onChange(of: snap.isCharging) { old, new in
            if old && !new { chargeStoppedAt = Date() }
        }
        // Fire the success flash when the battery lands at full / the limit right
        // after actually charging — not when it merely wakes up already-holding.
        .onChange(of: chargeComplete(snap)) { _, done in
            guard done, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let justCharged = snap.isCharging
                || (chargeStoppedAt.map { Date().timeIntervalSince($0) < 120 } ?? false)
            guard justCharged else { return }
            celebrating = true
            celebrateTicks = 0
        }
    }

    /// The battery has arrived where charging was headed: truly full, or held at
    /// the user's charge limit.
    private func chargeComplete(_ snap: BatterySnapshot) -> Bool {
        snap.isFullyCharged
            || (chargeLimit.limitEnabled && !chargeLimit.chargingEnabled
                && chargeLimit.pauseReason == "limit")
    }

    /// Icon tint: red warns when the battery is running warm or critically low,
    /// green while charging, otherwise neutral/adaptive.
    private func tint(for snap: BatterySnapshot) -> MenuBarTint {
        if isWarm(snap) { return .colored(.systemRed) }
        if snap.percentage <= 20 && !snap.isPluggedIn { return .colored(.systemRed) }
        if snap.isCharging { return .colored(.systemGreen) }
        return .neutral
    }

    /// Warm = charging held specifically for heat, or a genuinely hot battery
    /// (≥40 °C) even when heat-pause is off.
    private func isWarm(_ snap: BatterySnapshot) -> Bool {
        if chargeLimit.pauseReason == "heat" { return true }
        if let t = snap.temperature, t >= 40 { return true }
        return false
    }

    /// A tooltip explaining the current state — including *why* charging is paused.
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

/// How the menu-bar glyph should be coloured.
enum MenuBarTint {
    case neutral            // adaptive monochrome (template)
    case colored(NSColor)   // forced colour

    var isNeutral: Bool {
        if case .neutral = self { return true }
        return false
    }

    /// Stable key for glyph caching.
    var cacheKey: String {
        switch self {
        case .neutral: return "neutral"
        case .colored(let c): return "colored(\(c))"
        }
    }
}

extension BatterySnapshot {
    /// SF Symbol reflecting the current charge *level*. The charging bolt is drawn
    /// separately (see `MenuBarLabel`) so the fill level stays accurate even while
    /// charging — SF Symbols only ships a bolt variant for the full battery.
    var menuBarSymbol: String {
        switch percentage {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }

    /// Menu-bar glyph colour: green charging, red when critically low on battery,
    /// otherwise neutral/adaptive so it doesn't shout during normal use.
    var menuBarTint: MenuBarTint {
        if isCharging { return .colored(.systemGreen) }
        if percentage <= 20 && !isPluggedIn { return .colored(.systemRed) }
        return .neutral
    }
}
