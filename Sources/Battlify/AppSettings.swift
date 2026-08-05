import Foundation
import Combine

/// What text (if any) sits next to the menu-bar battery icon.
enum MenuBarDisplay: String, CaseIterable, Identifiable {
    /// Icon only.
    case icon
    /// "82%"
    case percentage
    /// "2:15" — time to full while charging, time to empty on battery.
    case timeRemaining
    /// "82% · 2:15"
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon:          return "Icon only"
        case .percentage:    return "Percentage"
        case .timeRemaining: return "Time remaining"
        case .both:          return "Percentage & time"
        }
    }

    var showsPercentage: Bool { self == .percentage || self == .both }
    var showsTime: Bool { self == .timeRemaining || self == .both }
}

/// GUI-only display preferences (UserDefaults), separate from the daemon's charge policy.
@MainActor
final class AppSettings: ObservableObject {
    /// What the menu-bar item shows next to the icon.
    @Published var menuBarDisplay: MenuBarDisplay {
        didSet { defaults.set(menuBarDisplay.rawValue, forKey: Keys.display) }
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
        static let showPct = "menubar.showPercentage"   // legacy Bool, migrated below
        static let display = "menubar.display"
        static let colorIcon = "menubar.colorIcon"
        static let animateIcon = "menubar.animateIcon"
        static let iconStyle = "menubar.iconStyle"
        static let notifications = "notifications.enabled"
        static let caffeineEndOnBattery = "caffeine.endOnBattery"
        static let caffeineDisplayOnBattery = "caffeine.keepDisplayOnBattery"
    }

    init() {
        // Migrate the old show-percentage Bool: off → icon only, on (or unset,
        // the first-run default) → percentage.
        if let raw = defaults.string(forKey: Keys.display),
           let mode = MenuBarDisplay(rawValue: raw) {
            menuBarDisplay = mode
        } else {
            menuBarDisplay = (defaults.object(forKey: Keys.showPct) as? Bool ?? true)
                ? .percentage : .icon
        }
        colorMenuBarIcon = defaults.object(forKey: Keys.colorIcon) as? Bool ?? true
        animateMenuBarIcon = defaults.bool(forKey: Keys.animateIcon)
        batteryIconStyle = (defaults.string(forKey: Keys.iconStyle))
            .flatMap(BatteryIconStyle.init(rawValue:)) ?? .rounded
        notificationsEnabled = defaults.bool(forKey: Keys.notifications)
        caffeineEndOnBattery = defaults.bool(forKey: Keys.caffeineEndOnBattery)
        caffeineKeepDisplayOnBattery = defaults.bool(forKey: Keys.caffeineDisplayOnBattery)
    }
}
