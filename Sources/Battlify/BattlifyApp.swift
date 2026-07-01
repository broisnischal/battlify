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
    @StateObject private var settings = AppSettings()
    @StateObject private var notifier = NotificationManager()

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
                .environmentObject(settings)
                .environmentObject(notifier)
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
                .environmentObject(chargeLimit)
                .environmentObject(automation)
                .environmentObject(license)
                .environmentObject(startup)
                .environmentObject(updater)
                .environmentObject(settings)
                .environmentObject(notifier)
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

    var body: some View {
        let snap = battery.snapshot
        // Respect the "color icon by state" preference; otherwise stay neutral.
        let tint: MenuBarTint = settings.colorMenuBarIcon ? tint(for: snap) : .neutral
        // The label renders at launch, so this is a reliable one-shot hook to wire
        // up notification detection (which then runs via Combine, not view lifecycle).
        notifier.startIfNeeded(settings: settings, battery: battery, chargeLimit: chargeLimit)
        return HStack(spacing: 2) {
            // Native SF Symbol battery, rendered as an NSImage so the state colour
            // actually shows in the menu bar (SwiftUI's `.foregroundStyle` is
            // overridden there by the template treatment for status-item labels).
            Image(nsImage: MenuBarLabel.glyph(snap.menuBarSymbol, tint: tint))
            // A separate bolt only while actually charging (not merely plugged in).
            if snap.isCharging {
                Image(nsImage: MenuBarLabel.glyph("bolt.fill", tint: tint))
            }
            if settings.showMenuBarPercentage {
                Text("\(snap.percentage)%")
            }
        }
        .help(helpText(snap))
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

    /// Build the status-item glyph. Neutral states stay as adaptive template
    /// images (match the menu bar); meaningful states use a fixed palette colour.
    static func glyph(_ symbol: String, tint: MenuBarTint) -> NSImage {
        var config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if case .colored(let color) = tint {
            config = config.applying(.init(paletteColors: [color]))
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = tint.isNeutral
        return image
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
