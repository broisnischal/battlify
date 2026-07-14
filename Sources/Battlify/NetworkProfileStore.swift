import Foundation
import Combine
import CoreLocation
import BattlifyKit

/// A rule: when joined to this Wi-Fi network, switch to this save mode.
struct NetworkProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var ssid: String
    var mode: SaveMode
}

/// Auto-switches the save mode based on the current Wi-Fi network. E.g. hold 80%
/// at home, charge to full on unknown/travel networks. Reading the joined SSID
/// needs Location permission on modern macOS, so the permission is only requested
/// once the user turns this on.
@MainActor
final class NetworkProfileStore: NSObject, ObservableObject {
    @Published var enabled: Bool { didSet { persist(); reconfigure() } }
    @Published private(set) var currentSSID: String?
    @Published private(set) var locationAuthorized = false
    /// SSID → mode rules.
    @Published var profiles: [NetworkProfile] { didSet { persist() } }
    /// Mode to apply on any network without a specific rule (nil = leave as-is).
    @Published var defaultMode: SaveMode? { didSet { persist() } }

    /// Set by the app so the store can apply modes through the daemon.
    weak var chargeLimit: ChargeLimitStore?

    private let defaults = UserDefaults.standard
    private let locationManager = CLLocationManager()
    private var timer: Timer?
    private var lastAppliedSSID: String?

    private enum Keys {
        static let enabled = "network.enabled"
        static let profiles = "network.profiles"
        static let defaultMode = "network.defaultMode"
    }

    override init() {
        enabled = defaults.bool(forKey: Keys.enabled)
        profiles = Self.loadProfiles(defaults)
        defaultMode = (defaults.string(forKey: Keys.defaultMode)).flatMap(SaveMode.init(rawValue:))
        super.init()
        locationManager.delegate = self
        locationAuthorized = Self.isAuthorized(locationManager.authorizationStatus)
        reconfigure()
    }

    /// Add a rule for the current network (or a typed SSID).
    func addProfile(ssid: String, mode: SaveMode) {
        let name = ssid.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let i = profiles.firstIndex(where: { $0.ssid == name }) {
            profiles[i].mode = mode
        } else {
            profiles.append(NetworkProfile(ssid: name, mode: mode))
        }
    }

    func removeProfile(_ profile: NetworkProfile) {
        profiles.removeAll { $0.id == profile.id }
    }

    /// Start/stop SSID monitoring and request Location access when enabling.
    private func reconfigure() {
        timer?.invalidate(); timer = nil
        guard enabled else { return }
        if !locationAuthorized { locationManager.requestWhenInUseAuthorization() }
        pollSSID()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollSSID() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Read the current SSID and apply its rule if it changed.
    private func pollSSID() {
        let ssid = RadioControl.currentSSID
        currentSSID = ssid
        guard enabled, let ssid else { return }
        guard ssid != lastAppliedSSID else { return }
        lastAppliedSSID = ssid

        // Only switch when a rule (or the default) resolves to a mode that isn't
        // already active. Re-applying the current mode would overwrite any custom
        // charge-limit/heat tweaks the user made within it — so joining a network on
        // launch or reconnecting shouldn't silently reset their settings.
        let mode = profiles.first(where: { $0.ssid == ssid })?.mode ?? defaultMode
        if let mode, mode != chargeLimit?.mode { chargeLimit?.applyMode(mode) }
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(defaultMode?.rawValue, forKey: Keys.defaultMode)
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Keys.profiles)
        }
    }

    private static func loadProfiles(_ defaults: UserDefaults) -> [NetworkProfile] {
        guard let data = defaults.data(forKey: Keys.profiles),
              let list = try? JSONDecoder().decode([NetworkProfile].self, from: data)
        else { return [] }
        return list
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorized
    }
}

extension NetworkProfileStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationAuthorized = Self.isAuthorized(status)
            if self.locationAuthorized { self.pollSSID() }
        }
    }
}
