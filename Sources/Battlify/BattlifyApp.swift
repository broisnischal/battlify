import SwiftUI
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
        } label: {
            // Menu bar label: battery glyph + percentage.
            let snap = battery.snapshot
            Image(systemName: snap.menuBarSymbol)
            Text("\(snap.percentage)%")
        }
        .menuBarExtraStyle(.window)

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

extension BatterySnapshot {
    /// SF Symbol that reflects charge level and charging state.
    var menuBarSymbol: String {
        if isCharging || (isPluggedIn && !isFullyCharged) {
            return "battery.100.bolt"
        }
        switch percentage {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }
}
