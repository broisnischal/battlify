import Foundation

/// How the MagSafe charge LED should behave.
public enum MagSafeLEDMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// macOS controls the LED (default — Battlify doesn't touch it).
    case system
    /// Reflect charge status: orange charging, green holding, off during the post-wake settling window.
    case status
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

/// How deeply the Mac sleeps when it's closed and idle.
///
/// `hibernatemode` is the whole lever on Apple silicon — the `standbydelay` knobs
/// Intel Macs had don't appear in `pmset -g cap` there, so there is nothing else
/// to tune. Writing it needs root, so the daemon applies it.
public enum SleepDepth: String, Codable, Sendable, CaseIterable, Identifiable {
    /// macOS default: memory stays powered, with an image written to disk as a
    /// safety net. Wakes instantly.
    case normal
    /// Memory is powered down and restored from disk on wake. Saves the trickle
    /// that keeping memory alive costs, at the price of a slower resume.
    case deep

    public var id: String { rawValue }

    public var hibernateMode: Int { self == .deep ? 25 : 3 }

    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .deep:   return "Deep"
        }
    }

    public var summary: String {
        switch self {
        case .normal:
            return "Memory stays powered while asleep, so the Mac wakes the moment you open the lid. The right choice unless you leave it closed for days at a time."
        case .deep:
            return "Powers memory down and restores it from disk. Saves the small trickle that keeping memory alive costs over a long sleep — but waking takes several seconds instead of being instant."
        }
    }
}

/// Persistent settings shared between the GUI (writer) and root daemon (reader).
/// Stored as JSON at a system-wide path so the daemon can read it for any logged-in user.
public struct BattlifyConfig: Codable, Equatable, Sendable {
    public var chargeLimitEnabled: Bool
    /// Upper charge threshold (%); charging stops at/above this.
    public var chargeLimit: Int
    /// Hysteresis: charging resumes below (chargeLimit - resumeMargin), avoiding toggle thrash.
    public var resumeMargin: Int
    /// Pause charging when the battery is too warm (heat accelerates wear).
    public var heatAwareEnabled: Bool
    /// Temperature (°C) at/above which charging pauses.
    public var maxChargeTempC: Double
    /// Legacy LED flag, kept for older daemon/GUI compat; `magSafeLedMode` is authoritative.
    public var magSafeLedEnabled: Bool
    public var magSafeLedMode: MagSafeLEDMode
    /// Force-discharge (run off battery while plugged) to bring the level down to the limit.
    public var dischargeEnabled: Bool
    /// Cut charging before sleep so macOS can't top up past the limit while the daemon is frozen.
    public var disableChargingBeforeSleep: Bool
    /// Hold a power assertion (while plugged) so idle-sleep can't interrupt limit enforcement.
    public var preventIdleSleep: Bool
    /// "Always Active": keep the Mac awake with the lid closed (`pmset disablesleep`).
    /// AC-only by default — auto-releases when unplugged (a closed Mac awake on battery
    /// runs hot and drains fast) unless `keepAwakeOnBattery` is set.
    public var keepAwake: Bool
    /// Opt-in: also keep awake with the lid closed on battery. Off by default (drains
    /// fast, runs hot); the `keepAwakeMaxTempC` guardrail still applies.
    public var keepAwakeOnBattery: Bool
    /// When true, keep-awake holds only while a matching task runs (see
    /// `keepAwakeProcesses` / `keepAwakeMinCpu`); when false, it holds until turned off.
    public var keepAwakeRequiresTask: Bool
    /// Process names (case-insensitive substring match) that keep the Mac awake, e.g. ["ffmpeg", "npm"].
    public var keepAwakeProcesses: [String]
    /// If > 0, any process using ≥ this %CPU also counts as "busy" (0 = names only).
    public var keepAwakeMinCpu: Double
    /// Thermal guardrail: release keep-awake at/above this °C to protect a closed Mac. 0 = off.
    public var keepAwakeMaxTempC: Double
    /// When task-gated keep-awake is on, actively put the Mac to sleep once the
    /// matching task finishes (instead of only releasing the hold and waiting for
    /// idle sleep). Lets an overnight build/download finish and then sleep right away.
    public var sleepWhenTaskDone: Bool

    /// Recurring charging windows (charge/hold/discharge on a weekly timetable).
    public var schedules: [ChargeSchedule]
    /// Once-daily "ready by" top-up target.
    public var readyBy: ReadyByTarget
    /// Legacy gentle-charging on/off flag; superseded by `chargePower` (kept in sync
    /// for older daemons).
    public var slowCharge: Bool
    /// Charge power 0–100% of full rate via duty-cycling the on/off switch (the hardware
    /// has no current dial, so it's an average). 100 = full rate; 0 = hold.
    public var chargePower: Int
    /// One-shot calibration: ignore the limit, charge to 100%, then auto-clear. Gives
    /// the battery an occasional full cycle.
    public var calibrateToFull: Bool
    /// Charging paused until this time (nil = not paused; distantFuture = until resumed).
    public var pauseUntil: Date?
    /// How deeply the Mac sleeps when closed and idle (see `SleepDepth`).
    public var sleepDepth: SleepDepth
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
                keepAwake: Bool = false,
                keepAwakeOnBattery: Bool = false,
                keepAwakeRequiresTask: Bool = false,
                keepAwakeProcesses: [String] = [],
                keepAwakeMinCpu: Double = 0,
                keepAwakeMaxTempC: Double = 0,
                sleepWhenTaskDone: Bool = false,
                schedules: [ChargeSchedule] = [],
                readyBy: ReadyByTarget = ReadyByTarget(),
                slowCharge: Bool = false,
                chargePower: Int = 100,
                calibrateToFull: Bool = false,
                pauseUntil: Date? = nil,
                sleepDepth: SleepDepth = .normal,
                mode: SaveMode = .off) {
        self.chargeLimitEnabled = chargeLimitEnabled
        self.chargeLimit = chargeLimit
        self.resumeMargin = resumeMargin
        self.heatAwareEnabled = heatAwareEnabled
        self.maxChargeTempC = maxChargeTempC
        self.magSafeLedEnabled = magSafeLedEnabled
        // New installs default to Status; older configs migrate from the legacy flag
        // in `init(from:)`.
        self.magSafeLedMode = magSafeLedMode ?? .status
        self.dischargeEnabled = dischargeEnabled
        self.disableChargingBeforeSleep = disableChargingBeforeSleep
        self.preventIdleSleep = preventIdleSleep
        self.keepAwake = keepAwake
        self.keepAwakeOnBattery = keepAwakeOnBattery
        self.keepAwakeRequiresTask = keepAwakeRequiresTask
        self.keepAwakeProcesses = keepAwakeProcesses
        self.keepAwakeMinCpu = keepAwakeMinCpu
        self.keepAwakeMaxTempC = keepAwakeMaxTempC
        self.sleepWhenTaskDone = sleepWhenTaskDone
        self.schedules = schedules
        self.readyBy = readyBy
        self.slowCharge = slowCharge
        self.chargePower = min(100, max(0, chargePower))
        self.calibrateToFull = calibrateToFull
        self.pauseUntil = pauseUntil
        self.sleepDepth = sleepDepth
        self.mode = mode
    }

    public static let `default` = BattlifyConfig()

    // Version-tolerant decoding: missing keys fall back to defaults.
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
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? false
        keepAwakeOnBattery = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeOnBattery) ?? false
        keepAwakeRequiresTask = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeRequiresTask) ?? false
        keepAwakeProcesses = try c.decodeIfPresent([String].self, forKey: .keepAwakeProcesses) ?? []
        keepAwakeMinCpu = try c.decodeIfPresent(Double.self, forKey: .keepAwakeMinCpu) ?? 0
        keepAwakeMaxTempC = try c.decodeIfPresent(Double.self, forKey: .keepAwakeMaxTempC) ?? 0
        sleepWhenTaskDone = try c.decodeIfPresent(Bool.self, forKey: .sleepWhenTaskDone) ?? false
        schedules = try c.decodeIfPresent([ChargeSchedule].self, forKey: .schedules) ?? []
        readyBy = try c.decodeIfPresent(ReadyByTarget.self, forKey: .readyBy) ?? ReadyByTarget()
        slowCharge = try c.decodeIfPresent(Bool.self, forKey: .slowCharge) ?? false
        // Migrate: configs predating `chargePower` map the legacy on/off flag to
        // 50% (the old Gentle-charging average); otherwise full power.
        chargePower = min(100, max(0, try c.decodeIfPresent(Int.self, forKey: .chargePower)
            ?? (slowCharge ? 50 : 100)))
        calibrateToFull = try c.decodeIfPresent(Bool.self, forKey: .calibrateToFull) ?? false
        pauseUntil = try c.decodeIfPresent(Date.self, forKey: .pauseUntil)
        sleepDepth = try c.decodeIfPresent(SleepDepth.self, forKey: .sleepDepth) ?? .normal
        mode = try c.decodeIfPresent(SaveMode.self, forKey: .mode) ?? .off
    }
}

public enum BattlifyPaths {
    /// System-wide config dir under /Library for daemon visibility. Made writable by
    /// the GUI via the installer (or the helper).
    public static let configDirectory =
        URL(fileURLWithPath: "/Library/Application Support/Battlify", isDirectory: true)

    public static let configFile =
        configDirectory.appendingPathComponent("config.json")

    /// Where the root daemon appends periodic battery samples.
    public static let historyFile =
        configDirectory.appendingPathComponent("history.jsonl")

    /// Per-user config dir, used when the GUI records history itself (no root daemon).
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
