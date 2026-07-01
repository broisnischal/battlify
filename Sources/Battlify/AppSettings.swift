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

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let showPct = "menubar.showPercentage"
        static let colorIcon = "menubar.colorIcon"
    }

    init() {
        // Default both on for first run (matches prior behavior).
        showMenuBarPercentage = defaults.object(forKey: Keys.showPct) as? Bool ?? true
        colorMenuBarIcon = defaults.object(forKey: Keys.colorIcon) as? Bool ?? true
    }
}
