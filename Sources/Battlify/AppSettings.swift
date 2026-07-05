import Foundation
import Combine

/// GUI-only display preferences (UserDefaults). These are separate from the
/// daemon's charge policy — they just control how the app presents itself.
@MainActor
final class AppSettings: ObservableObject {
    /// Show the battery percentage next to the menu-bar icon.
    @Published var showMenuBarPercentage: Bool {
        didSet { defaults.set(showMenuBarPercentage, forKey: Keys.showPct) }
    }
    /// Tint the menu-bar icon by charge state (green charging / red low). When
    /// off, the icon stays monochrome and adapts to the menu bar like a system icon.
    @Published var colorMenuBarIcon: Bool {
        didSet { defaults.set(colorMenuBarIcon, forKey: Keys.colorIcon) }
    }
    /// Which battery glyph to draw in the menu bar (see `BatteryIconStyle`).
    @Published var batteryIconStyle: BatteryIconStyle {
        didSet { defaults.set(batteryIconStyle.rawValue, forKey: Keys.iconStyle) }
    }
    /// Post macOS notifications for charge events (limit reached, heat pause, low
    /// battery, fully charged). Off by default so we don't prompt for permission
    /// until the user opts in.
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let showPct = "menubar.showPercentage"
        static let colorIcon = "menubar.colorIcon"
        static let iconStyle = "menubar.iconStyle"
        static let notifications = "notifications.enabled"
    }

    init() {
        // Default both on for first run (matches prior behavior).
        showMenuBarPercentage = defaults.object(forKey: Keys.showPct) as? Bool ?? true
        colorMenuBarIcon = defaults.object(forKey: Keys.colorIcon) as? Bool ?? true
        batteryIconStyle = (defaults.string(forKey: Keys.iconStyle))
            .flatMap(BatteryIconStyle.init(rawValue:)) ?? .rounded
        notificationsEnabled = defaults.bool(forKey: Keys.notifications)
    }
}
