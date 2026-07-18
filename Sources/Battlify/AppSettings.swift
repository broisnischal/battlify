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
    @Published var batteryIconStyle: BatteryIconStyle {
        didSet { defaults.set(batteryIconStyle.rawValue, forKey: Keys.iconStyle) }
    }
    /// Off by default so we don't prompt for notification permission until opt-in.
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }
    /// Play the full-screen dot-matrix charging animation when the charger is plugged in.
    @Published var chargingAnimationEnabled: Bool {
        didSet { defaults.set(chargingAnimationEnabled, forKey: Keys.chargeAnim) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let showPct = "menubar.showPercentage"
        static let colorIcon = "menubar.colorIcon"
        static let iconStyle = "menubar.iconStyle"
        static let notifications = "notifications.enabled"
        static let chargeAnim = "chargingAnimation.enabled"
    }

    init() {
        showMenuBarPercentage = defaults.object(forKey: Keys.showPct) as? Bool ?? true
        colorMenuBarIcon = defaults.object(forKey: Keys.colorIcon) as? Bool ?? true
        batteryIconStyle = (defaults.string(forKey: Keys.iconStyle))
            .flatMap(BatteryIconStyle.init(rawValue:)) ?? .rounded
        notificationsEnabled = defaults.bool(forKey: Keys.notifications)
        chargingAnimationEnabled = defaults.object(forKey: Keys.chargeAnim) as? Bool ?? true
    }
}
