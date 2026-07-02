import Foundation
import Combine
import CryptoKit
import BattlifyKit

/// Second copy of the trial-usage ledger, outside UserDefaults, so a plain
/// `defaults delete com.battlify.app` doesn't grant a fresh 30 days — usage is
/// the union of both stores, and each re-populates the other. The day list is
/// HMAC'd with a key derived from this Mac's hardware UUID, so hand-editing the
/// file (or copying an empty one from another machine) just invalidates it,
/// which reads as an empty set and loses nothing from UserDefaults.
private enum TrialVault {
    private struct Ledger: Codable {
        var d: [String]   // "yyyy-MM-dd" days the app was used
        var h: String     // HMAC-SHA256 over the sorted, comma-joined days
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".com.battlify.usage", isDirectory: false)
    }

    private static var hmacKey: SymmetricKey {
        let seed = "battlify.trial:" + (DeviceIdentity.hardwareUUID() ?? "")
        return SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))
    }

    private static func mac(_ days: [String]) -> String {
        let message = Data(days.joined(separator: ",").utf8)
        return HMAC<SHA256>.authenticationCode(for: message, using: hmacKey)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data),
              ledger.d == ledger.d.sorted(),
              ledger.h == mac(ledger.d)
        else { return [] }
        return Set(ledger.d)
    }

    static func save(_ days: Set<String>) {
        let sorted = days.sorted()
        guard let data = try? JSONEncoder().encode(Ledger(d: sorted, h: mac(sorted))) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Licensing:
///  - **Use-based 30-day trial**: a free day is only counted on days you actually
///    use Battlify (not calendar days), so the trial isn't "wasted" while idle.
///    Usage is double-booked (UserDefaults + TrialVault) to survive casual resets.
///  - **$2.99 one-time** license, verified offline with an embedded Ed25519 public
///    key — no phone-home, works without a network. Keys are bound to one Mac.
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

    /// This Mac's device code — shown in the UI so the buyer can enter it at
    /// checkout; the storefront signs it into the license, binding it to this Mac.
    /// Empty string (never nil) on IOKit failure so device-bound licenses are
    /// still rejected rather than silently accepted.
    nonisolated static let deviceCode = DeviceIdentity.deviceCode() ?? ""
    var deviceCode: String { Self.deviceCode }

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
        t.tolerance = 1800   // day-counting heartbeat; precise timing irrelevant
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
        days.formUnion(TrialVault.load())
        days.insert(today())
        defaults.set(Array(days), forKey: Keys.usedDays)
        TrialVault.save(days)
    }

    var daysUsed: Int {
        Set(defaults.stringArray(forKey: Keys.usedDays) ?? []).union(TrialVault.load()).count
    }

    // MARK: - State

    func refresh() {
        // A valid, non-expired stored license wins.
        if let key = defaults.string(forKey: Keys.licenseKey),
           let info = try? License.verify(key, deviceID: Self.deviceCode) {
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
            let info = try License.verify(key, deviceID: Self.deviceCode)
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
