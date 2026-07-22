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
                .onAppear {
                    network.chargeLimit = chargeLimit
                    automation.chargeLimit = chargeLimit
                    endurance.start(chargeLimit: chargeLimit)
                }
        } label: {
            // Its own observing view so it re-renders reliably — a label closure that
            // reads the store inline can render once and go stale.
            MenuBarLabel(battery: battery, chargeLimit: chargeLimit,
                         settings: settings, notifier: notifier)
        }
        .menuBarExtraStyle(.window)

        // Set-once controls live here so the menu dropdown stays focused on daily use.
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
                .environmentObject(endurance)
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

    /// Animation tick for the menu-bar glyph. Only runs while an animation is visible —
    /// never while discharging (a battery saver shouldn't burn cycles on battery).
    @State private var animFrame = 0
    @State private var celebrating = false
    @State private var celebrateTicks = 0
    /// When charging last stopped — to tell "just finished" from arriving full via wake.
    @State private var chargeStoppedAt: Date?

    var body: some View {
        let snap = battery.snapshot
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let celebratingNow = celebrating && !reduceMotion
        // Success flash is green only when coloring is on; mono blinks by alpha instead.
        let tint: MenuBarTint =
            celebratingNow && settings.colorMenuBarIcon ? .colored(.systemGreen)
            : settings.colorMenuBarIcon ? tint(for: snap) : .neutral
        let animating = !reduceMotion && (snap.isCharging || celebrating)
        // The label renders at launch — a reliable hook to start notification detection.
        notifier.startIfNeeded(settings: settings, battery: battery, chargeLimit: chargeLimit)
        return HStack(spacing: 2) {
            // Drawn as an NSImage: SwiftUI's .foregroundStyle is overridden for status-item
            // labels, and the renderer draws the charging bolt inside the glyph.
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
        // One shared ~0.5s tick; task(id:) cancels it when nothing animates.
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
        // Flash only when it lands full/at-limit right after charging, not on wake-already-holding.
        .onChange(of: chargeComplete(snap)) { _, done in
            guard done, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let justCharged = snap.isCharging
                || (chargeStoppedAt.map { Date().timeIntervalSince($0) < 120 } ?? false)
            guard justCharged else { return }
            celebrating = true
            celebrateTicks = 0
        }
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
