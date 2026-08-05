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
    /// Caffeine: end the session the moment you unplug. Off by default — work keeps
    /// running on battery, just without the screen (see below).
    @Published var caffeineEndOnBattery: Bool {
        didSet { defaults.set(caffeineEndOnBattery, forKey: Keys.caffeineEndOnBattery) }
    }
    /// Caffeine: keep the screen lit on battery too. Off by default: a lit idle screen
    /// costs percents per hour, and keeping only the system awake finishes the same work.
    @Published var caffeineKeepDisplayOnBattery: Bool {
        didSet { defaults.set(caffeineKeepDisplayOnBattery, forKey: Keys.caffeineDisplayOnBattery) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let showPct = "menubar.showPercentage"
        static let colorIcon = "menubar.colorIcon"
        static let animateIcon = "menubar.animateIcon"
        static let iconStyle = "menubar.iconStyle"
        static let notifications = "notifications.enabled"
        static let caffeineEndOnBattery = "caffeine.endOnBattery"
        static let caffeineDisplayOnBattery = "caffeine.keepDisplayOnBattery"
    }

    init() {
        showMenuBarPercentage = defaults.object(forKey: Keys.showPct) as? Bool ?? true
        colorMenuBarIcon = defaults.object(forKey: Keys.colorIcon) as? Bool ?? true
        animateMenuBarIcon = defaults.bool(forKey: Keys.animateIcon)
        batteryIconStyle = (defaults.string(forKey: Keys.iconStyle))
            .flatMap(BatteryIconStyle.init(rawValue:)) ?? .rounded
        notificationsEnabled = defaults.bool(forKey: Keys.notifications)
        caffeineEndOnBattery = defaults.bool(forKey: Keys.caffeineEndOnBattery)
        caffeineKeepDisplayOnBattery = defaults.bool(forKey: Keys.caffeineDisplayOnBattery)
    }
}
