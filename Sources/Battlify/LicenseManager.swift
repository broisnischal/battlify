import Foundation
import Combine
import BattlifyKit

/// Manages trial + activation state for the GUI. Stores the license key and the
/// first-run date in UserDefaults and derives the current entitlement.
@MainActor
final class LicenseManager: ObservableObject {
    enum State: Equatable {
        case licensed(name: String)
        case trial(daysLeft: Int)
        case expired
    }

    @Published private(set) var state: State = .trial(daysLeft: 0)
    @Published var enteredKey: String = ""
    @Published private(set) var lastError: String?

    /// Whether premium controls are unlocked (active trial or valid license).
    var isPro: Bool {
        switch state {
        case .licensed, .trial: return true
        case .expired: return false
        }
    }

    /// True only when a valid license is installed (not merely on trial).
    var isLicensed: Bool {
        if case .licensed = state { return true }
        return false
    }

    private let defaults = UserDefaults.standard
    private let trialDays = 14
    private enum Keys {
        static let key = "license.key"
        static let firstRun = "license.firstRun"
    }

    init() { refresh() }

    func refresh() {
        // Valid stored license wins.
        if let key = defaults.string(forKey: Keys.key),
           let info = try? License.verify(key) {
            state = .licensed(name: info.name.isEmpty ? info.email : info.name)
            return
        }
        // Otherwise, compute trial from first run.
        let firstRun: Date
        if let stored = defaults.object(forKey: Keys.firstRun) as? Date {
            firstRun = stored
        } else {
            firstRun = Date()
            defaults.set(firstRun, forKey: Keys.firstRun)
        }
        let elapsed = Calendar.current.dateComponents([.day], from: firstRun, to: Date()).day ?? 0
        let left = trialDays - elapsed
        state = left > 0 ? .trial(daysLeft: left) : .expired
    }

    /// Validate and store the entered key.
    func activate() {
        let key = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { lastError = "Paste your license key first."; return }
        do {
            let info = try License.verify(key)
            defaults.set(key, forKey: Keys.key)
            enteredKey = ""
            lastError = nil
            state = .licensed(name: info.name.isEmpty ? info.email : info.name)
        } catch {
            lastError = (error as? LicenseError)?.description ?? "\(error)"
        }
    }

    func deactivate() {
        defaults.removeObject(forKey: Keys.key)
        refresh()
    }

    var statusText: String {
        switch state {
        case .licensed(let name): return "Licensed to \(name)"
        case .trial(let d): return "Trial — \(d) day\(d == 1 ? "" : "s") left"
        case .expired: return "Trial expired"
        }
    }
}
