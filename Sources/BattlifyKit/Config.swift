import Foundation

/// How the MagSafe charge LED should behave.
public enum MagSafeLEDMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// macOS controls the LED (default — Battlify doesn't touch it).
    case system
    /// Reflect charge status: orange charging, green holding at the limit, and
    /// off for a short "settling" window right after the Mac wakes.
    case status
    /// Force the LED off at all times.
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "Auto"
        case .status: return "Status"
        case .off:    return "Off"
        }
    }
}

/// Persistent settings shared between the GUI (writer) and the root daemon (reader).
/// Stored as JSON at a system-wide path so the root daemon can read it regardless
/// of which user is logged in.
public struct BattlifyConfig: Codable, Equatable, Sendable {
    /// Whether charge limiting is active.
    public var chargeLimitEnabled: Bool
    /// Upper charge threshold (%). Charging stops at/above this.
    public var chargeLimit: Int
    /// Hysteresis: charging resumes once below (chargeLimit - resumeMargin).
    /// Prevents rapid on/off toggling around the threshold.
    public var resumeMargin: Int
    /// Pause charging when the battery is too warm (heat accelerates wear).
    public var heatAwareEnabled: Bool
    /// Temperature (°C) at/above which charging pauses.
    public var maxChargeTempC: Double
    /// Drive the MagSafe LED from charge status (orange charging, green holding).
    /// Legacy flag, kept for older daemon/GUI compatibility; `magSafeLedMode` is
    /// authoritative and is derived from this when a config predates the mode.
    public var magSafeLedEnabled: Bool
    /// How the MagSafe LED behaves (Auto / Show status / Off).
    public var magSafeLedMode: MagSafeLEDMode
    /// Force-discharge (run off battery while plugged) to bring the level down to
    /// the limit when you plug in above it.
    public var dischargeEnabled: Bool
    /// Cut charging just before the Mac sleeps so macOS can't top the battery up
    /// past the limit overnight (the daemon is frozen during sleep and can't).
    public var disableChargingBeforeSleep: Bool
    /// Hold a power assertion (while plugged in) so the Mac won't idle-sleep,
    /// keeping the charge limit continuously enforced.
    public var preventIdleSleep: Bool
    /// One-shot calibration: temporarily ignore the limit and charge to 100%,
    /// then auto-clear once full. Batteries benefit from an occasional full cycle.
    public var calibrateToFull: Bool
    /// Charging is paused until this time (nil = not paused; distantFuture =
    /// paused indefinitely until the user resumes).
    public var pauseUntil: Date?
    /// The last-applied save mode.
    public var mode: SaveMode

    public init(chargeLimitEnabled: Bool = false,
                chargeLimit: Int = 80,
                resumeMargin: Int = 5,
                heatAwareEnabled: Bool = false,
                maxChargeTempC: Double = 35.0,
                magSafeLedEnabled: Bool = false,
                magSafeLedMode: MagSafeLEDMode? = nil,
                dischargeEnabled: Bool = false,
                disableChargingBeforeSleep: Bool = false,
                preventIdleSleep: Bool = false,
                calibrateToFull: Bool = false,
                pauseUntil: Date? = nil,
                mode: SaveMode = .off) {
        self.chargeLimitEnabled = chargeLimitEnabled
        self.chargeLimit = chargeLimit
        self.resumeMargin = resumeMargin
        self.heatAwareEnabled = heatAwareEnabled
        self.maxChargeTempC = maxChargeTempC
        self.magSafeLedEnabled = magSafeLedEnabled
        // Default the mode from the legacy flag when not explicitly given.
        self.magSafeLedMode = magSafeLedMode ?? (magSafeLedEnabled ? .status : .system)
        self.dischargeEnabled = dischargeEnabled
        self.disableChargingBeforeSleep = disableChargingBeforeSleep
        self.preventIdleSleep = preventIdleSleep
        self.calibrateToFull = calibrateToFull
        self.pauseUntil = pauseUntil
        self.mode = mode
    }

    public static let `default` = BattlifyConfig()

    // Version-tolerant decoding: missing keys fall back to defaults so configs
    // written by older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chargeLimitEnabled = try c.decodeIfPresent(Bool.self, forKey: .chargeLimitEnabled) ?? false
        chargeLimit = try c.decodeIfPresent(Int.self, forKey: .chargeLimit) ?? 80
        resumeMargin = try c.decodeIfPresent(Int.self, forKey: .resumeMargin) ?? 5
        heatAwareEnabled = try c.decodeIfPresent(Bool.self, forKey: .heatAwareEnabled) ?? false
        maxChargeTempC = try c.decodeIfPresent(Double.self, forKey: .maxChargeTempC) ?? 35.0
        magSafeLedEnabled = try c.decodeIfPresent(Bool.self, forKey: .magSafeLedEnabled) ?? false
        // Migrate: if the mode key is missing (older config), derive it from the flag.
        magSafeLedMode = try c.decodeIfPresent(MagSafeLEDMode.self, forKey: .magSafeLedMode)
            ?? (magSafeLedEnabled ? .status : .system)
        dischargeEnabled = try c.decodeIfPresent(Bool.self, forKey: .dischargeEnabled) ?? false
        disableChargingBeforeSleep = try c.decodeIfPresent(Bool.self, forKey: .disableChargingBeforeSleep) ?? false
        preventIdleSleep = try c.decodeIfPresent(Bool.self, forKey: .preventIdleSleep) ?? false
        calibrateToFull = try c.decodeIfPresent(Bool.self, forKey: .calibrateToFull) ?? false
        pauseUntil = try c.decodeIfPresent(Date.self, forKey: .pauseUntil)
        mode = try c.decodeIfPresent(SaveMode.self, forKey: .mode) ?? .off
    }
}

public enum BattlifyPaths {
    /// System-wide config directory, readable by root daemon and writable by
    /// the GUI (the installer makes it group/everyone-writable, or the GUI
    /// writes via the helper). Kept under /Library for daemon visibility.
    public static let configDirectory =
        URL(fileURLWithPath: "/Library/Application Support/Battlify", isDirectory: true)

    public static let configFile =
        configDirectory.appendingPathComponent("config.json")

    /// Where the root daemon appends periodic battery samples.
    public static let historyFile =
        configDirectory.appendingPathComponent("history.jsonl")

    /// Per-user config dir, used by the GUI when it records history itself
    /// (e.g. when the root daemon isn't installed).
    public static var userConfigDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Battlify", isDirectory: true)
    }

    public static var userHistoryFile: URL {
        userConfigDirectory.appendingPathComponent("history.jsonl")
    }
}

public enum ConfigStore {
    public static func load() -> BattlifyConfig {
        guard let data = try? Data(contentsOf: BattlifyPaths.configFile),
              let cfg = try? JSONDecoder().decode(BattlifyConfig.self, from: data)
        else { return .default }
        return cfg
    }

    /// Write the config. Throws if the directory isn't writable by this process.
    public static func save(_ config: BattlifyConfig) throws {
        try FileManager.default.createDirectory(
            at: BattlifyPaths.configDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(config)
        try data.write(to: BattlifyPaths.configFile, options: .atomic)
    }
}
