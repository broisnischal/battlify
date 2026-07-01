import Foundation
import Combine
import BattlifyKit

/// Licensing:
///  - **Use-based 30-day trial**: a free day is only counted on days you actually
///    use Battlify (not calendar days), so the trial isn't "wasted" while idle.
///  - **$2.99 one-time** license, verified offline with an embedded Ed25519 public
///    key — no phone-home, works without a network.
@MainActor
final class LicenseManager: ObservableObject {
    enum State: Equatable {
        case licensed(name: String)
        case trial(daysLeft: Int)
        case expired
    }

    @Published private(set) var state: State = .trial(daysLeft: 30)
    @Published var enteredKey: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var verifying = false

    /// Premium controls unlocked (active trial or valid license).
    var isPro: Bool {
        switch state { case .licensed, .trial: return true; case .expired: return false }
    }
    var isLicensed: Bool {
        if case .licensed = state { return true }; return false
    }

    let trialDays = 30
    private let defaults = UserDefaults.standard
    private enum Keys {
        static let licenseKey = "license.key"
        static let licenseEmail = "license.email"
        static let usedDays = "trial.usedDays"   // [String] yyyy-MM-dd
    }

    private var dayTimer: Timer?

    init() {
        recordUsageToday()
        refresh()
        // Count each new day of use while the app keeps running.
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordUsageToday(); self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        dayTimer = t
    }

    // MARK: - Trial accounting

    private func today() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func recordUsageToday() {
        var days = Set(defaults.stringArray(forKey: Keys.usedDays) ?? [])
        days.insert(today())
        defaults.set(Array(days), forKey: Keys.usedDays)
    }

    var daysUsed: Int { (defaults.stringArray(forKey: Keys.usedDays) ?? []).count }

    // MARK: - State

    func refresh() {
        // A valid, non-expired stored license wins.
        if let key = defaults.string(forKey: Keys.licenseKey),
           let info = try? License.verify(key) {
            state = .licensed(name: info.name.isEmpty ? info.email : info.name)
            return
        }
        let left = max(0, trialDays - daysUsed)
        state = left > 0 ? .trial(daysLeft: left) : .expired
    }

    // MARK: - Activation (offline Ed25519)

    func activate() {
        let key = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { lastError = "Paste your license key first."; return }
        do {
            let info = try License.verify(key)
            let name = info.name.isEmpty ? info.email : info.name
            defaults.set(key, forKey: Keys.licenseKey)
            defaults.set(name, forKey: Keys.licenseEmail)
            enteredKey = ""
            lastError = nil
            state = .licensed(name: name)
        } catch {
            lastError = (error as? LicenseError)?.description ?? "That license key isn't valid."
        }
    }

    func deactivate() {
        defaults.removeObject(forKey: Keys.licenseKey)
        defaults.removeObject(forKey: Keys.licenseEmail)
        refresh()
    }

    var statusText: String {
        switch state {
        case .licensed(let name): return "Licensed · \(name)"
        case .trial(let d): return "Trial — \(d) free day\(d == 1 ? "" : "s") left"
        case .expired: return "Trial ended"
        }
    }
}
