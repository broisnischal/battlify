import Foundation

/// Persistent settings shared between the GUI (writer) and the root daemon (reader).
/// Stored as JSON at a system-wide path so the root daemon can read it regardless
/// of which user is logged in.
public struct BattPieConfig: Codable, Equatable, Sendable {
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
    /// The last-applied save mode.
    public var mode: SaveMode

    public init(chargeLimitEnabled: Bool = false,
                chargeLimit: Int = 80,
                resumeMargin: Int = 5,
                heatAwareEnabled: Bool = false,
                maxChargeTempC: Double = 35.0,
                mode: SaveMode = .off) {
        self.chargeLimitEnabled = chargeLimitEnabled
        self.chargeLimit = chargeLimit
        self.resumeMargin = resumeMargin
        self.heatAwareEnabled = heatAwareEnabled
        self.maxChargeTempC = maxChargeTempC
        self.mode = mode
    }

    public static let `default` = BattPieConfig()

    // Version-tolerant decoding: missing keys fall back to defaults so configs
    // written by older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chargeLimitEnabled = try c.decodeIfPresent(Bool.self, forKey: .chargeLimitEnabled) ?? false
        chargeLimit = try c.decodeIfPresent(Int.self, forKey: .chargeLimit) ?? 80
        resumeMargin = try c.decodeIfPresent(Int.self, forKey: .resumeMargin) ?? 5
        heatAwareEnabled = try c.decodeIfPresent(Bool.self, forKey: .heatAwareEnabled) ?? false
        maxChargeTempC = try c.decodeIfPresent(Double.self, forKey: .maxChargeTempC) ?? 35.0
        mode = try c.decodeIfPresent(SaveMode.self, forKey: .mode) ?? .off
    }
}

public enum BattPiePaths {
    /// System-wide config directory, readable by root daemon and writable by
    /// the GUI (the installer makes it group/everyone-writable, or the GUI
    /// writes via the helper). Kept under /Library for daemon visibility.
    public static let configDirectory =
        URL(fileURLWithPath: "/Library/Application Support/BattPie", isDirectory: true)

    public static let configFile =
        configDirectory.appendingPathComponent("config.json")

    /// Where the root daemon appends periodic battery samples.
    public static let historyFile =
        configDirectory.appendingPathComponent("history.jsonl")

    /// Per-user config dir, used by the GUI when it records history itself
    /// (e.g. when the root daemon isn't installed).
    public static var userConfigDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BattPie", isDirectory: true)
    }

    public static var userHistoryFile: URL {
        userConfigDirectory.appendingPathComponent("history.jsonl")
    }
}

public enum ConfigStore {
    public static func load() -> BattPieConfig {
        guard let data = try? Data(contentsOf: BattPiePaths.configFile),
              let cfg = try? JSONDecoder().decode(BattPieConfig.self, from: data)
        else { return .default }
        return cfg
    }

    /// Write the config. Throws if the directory isn't writable by this process.
    public static func save(_ config: BattPieConfig) throws {
        try FileManager.default.createDirectory(
            at: BattPiePaths.configDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(config)
        try data.write(to: BattPiePaths.configFile, options: .atomic)
    }
}
