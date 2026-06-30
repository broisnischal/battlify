import Foundation

/// A bundle of settings applied together by a save mode. `powerNap`,
/// `wakeOnNetwork`, and `tcpKeepAlive` are the *feature* states (true = active /
/// using power), matching their pmset values.
public struct SaveProfile: Sendable, Equatable {
    public var chargeLimitEnabled: Bool
    public var chargeLimit: Int
    public var heatAwareEnabled: Bool
    public var maxChargeTempC: Double
    public var lowPowerMode: Bool
    public var powerNap: Bool
    public var wakeOnNetwork: Bool
    public var tcpKeepAlive: Bool
    public var wifiOffOnLidClose: Bool
    public var bluetoothOffOnLidClose: Bool
    public var restoreOnWake: Bool
}

/// One-tap battery profiles.
public enum SaveMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case off          // no saving — back to normal macOS behavior
    case normal       // balanced everyday saving
    case superSaver   // maximum battery life

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .normal: return "Normal"
        case .superSaver: return "Super Saver"
        }
    }

    public var summary: String {
        switch self {
        case .off:
            return "No battery saving — standard macOS behavior."
        case .normal:
            return "Charge limit 80%, pause when warm, Power Nap off. Find My stays active."
        case .superSaver:
            return "Low Power Mode, charge limit 80%, pause when warm, all sleep wake-ups off, Wi-Fi & Bluetooth off when closed."
        }
    }

    public var profile: SaveProfile {
        switch self {
        case .off:
            return SaveProfile(
                chargeLimitEnabled: false, chargeLimit: 80,
                heatAwareEnabled: false, maxChargeTempC: 35.0,
                lowPowerMode: false,
                powerNap: true, wakeOnNetwork: false, tcpKeepAlive: true,
                wifiOffOnLidClose: false, bluetoothOffOnLidClose: false,
                restoreOnWake: true)

        case .normal:
            return SaveProfile(
                chargeLimitEnabled: true, chargeLimit: 80,
                heatAwareEnabled: true, maxChargeTempC: 35.0,
                lowPowerMode: false,
                powerNap: false, wakeOnNetwork: false, tcpKeepAlive: true,
                wifiOffOnLidClose: false, bluetoothOffOnLidClose: false,
                restoreOnWake: true)

        case .superSaver:
            return SaveProfile(
                chargeLimitEnabled: true, chargeLimit: 80,
                heatAwareEnabled: true, maxChargeTempC: 33.0,
                lowPowerMode: true,
                powerNap: false, wakeOnNetwork: false, tcpKeepAlive: false,
                wifiOffOnLidClose: true, bluetoothOffOnLidClose: true,
                restoreOnWake: true)
        }
    }
}
