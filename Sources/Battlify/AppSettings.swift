import Foundation
import Combine

/// GUI-only display preferences (UserDefaults), separate from the daemon's charge policy.
@MainActor
final class AppSettings: ObservableObject {
    @Published var showMenuBarPercentage: Bool {
        didSet { defaults.set(showMenuBarPercentage, forKey: Keys.showPct) }
    }
    @Published var colorMenuBarIcon: Bool {
        didSet { defaults.set(colorMenuBarIcon, forKey: Keys.colorIcon) }
    }
    /// Animate the glyph while charging. Off by default: the tick re-renders the
    /// status item twice a second, and a status-item relayout is expensive enough
    /// that it measured ~10% of a core for the whole time the Mac was plugged in.
    /// A battery app shouldn't spend that on a moving picture unless asked.
    @Published var animateMenuBarIcon: Bool {
        didSet { defaults.set(animateMenuBarIcon, forKey: Keys.animateIcon) }
    }
    @Published var batteryIconStyle: BatteryIconStyle {
        didSet { defaults.set(batteryIconStyle.rawValue, forKey: Keys.iconStyle) }
    }
    /// Off by default so we don't prompt for notification permission until opt-in.
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let showPct = "menubar.showPercentage"
        static let colorIcon = "menubar.colorIcon"
        static let animateIcon = "menubar.animateIcon"
        static let iconStyle = "menubar.iconStyle"
        static let notifications = "notifications.enabled"
    }

    init() {
        showMenuBarPercentage = defaults.object(forKey: Keys.showPct) as? Bool ?? true
        colorMenuBarIcon = defaults.object(forKey: Keys.colorIcon) as? Bool ?? true
        animateMenuBarIcon = defaults.bool(forKey: Keys.animateIcon)
        batteryIconStyle = (defaults.string(forKey: Keys.iconStyle))
            .flatMap(BatteryIconStyle.init(rawValue:)) ?? .rounded
        notificationsEnabled = defaults.bool(forKey: Keys.notifications)
    }
}
