import Foundation

/// Control protocol between the GUI (client) and the root daemon (server),
/// spoken over a Unix domain socket as newline-delimited JSON.

/// System sleep/idle power features that drain battery while the lid is closed.
/// Raw values are the matching `pmset` keys.
public enum PowerToggle: String, Codable, Sendable, CaseIterable {
    case powerNap = "powernap"
    case wakeOnNetwork = "womp"
    case tcpKeepAlive = "tcpkeepalive"
    case dimOnBattery = "lessbright"

    /// Where a toggle belongs in the UI.
    public enum Category: Sendable {
        case sleepWake       // features that keep the Mac busy during sleep
        case batteryOptions  // macOS "Battery > Options" style tweaks
    }

    /// Which pmset power source this toggle applies to.
    public enum Scope: String, Sendable {
        case all = "-a"
        case battery = "-b"
        case ac = "-c"
    }

    public var category: Category {
        switch self {
        case .powerNap, .wakeOnNetwork, .tcpKeepAlive: return .sleepWake
        case .dimOnBattery: return .batteryOptions
        }
    }

    /// `dimOnBattery` is battery-only (`-b`); the rest apply to all sources.
    public var scope: Scope {
        switch self {
        case .dimOnBattery: return .battery
        default: return .all
        }
    }

    public var title: String {
        switch self {
        case .powerNap: return "Power Nap"
        case .wakeOnNetwork: return "Wake for network access"
        case .tcpKeepAlive: return "Keep network alive in sleep"
        case .dimOnBattery: return "Slightly dim the display on battery"
        }
    }

    public var hint: String {
        switch self {
        case .powerNap: return "Wakes periodically while closed to sync Mail/iCloud"
        case .wakeOnNetwork: return "Lets other devices wake this Mac over the network"
        case .tcpKeepAlive: return "Keeps Find My & push active during sleep"
        case .dimOnBattery: return "Lowers brightness a little when unplugged to stretch battery life"
        }
    }
}

public enum ControlRequest: Codable, Sendable {
    case getStatus
    case setConfig(BattlifyConfig)
    case setLowPowerMode(Bool)
    case setPowerToggle(PowerToggle, Bool)
    case applyMode(SaveMode)
    /// Pause charging: minutes > 0 = for that long; 0 = resume now;
    /// -1 = pause indefinitely until resumed.
    case pauseCharging(Int)
    /// The Mac is about to sleep — cut charging now if configured to.
    case prepareForSleep
    /// Start (true) or cancel (false) a one-shot charge-to-100% calibration.
    case calibrateToFull(Bool)
    /// Delete the daemon-written history file. The GUI can't (root-owned dir), so it
    /// asks the daemon.
    case clearSamples
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var config: BattlifyConfig
    public var batteryPercent: Int
    public var chargingEnabled: Bool
    public var schemeDescription: String
    public var lowPowerModeEnabled: Bool
    /// Current state of each PowerToggle, keyed by its raw pmset key.
    public var powerToggles: [String: Bool]
    /// Why charging is paused: "limit", "heat", "paused", or nil.
    public var pauseReason: String?
    public var magSafeSupported: Bool
    public var dischargeSupported: Bool
    public var discharging: Bool
    public var message: String?
    /// Protocol version of the responding daemon. Older daemons omit it → decode to 0 → outdated.
    public var daemonProtocolVersion: Int
    /// Behaviour/build version of the daemon (see `HelperBuild`). Lets the GUI update a
    /// helper that's protocol-current but behaviour-stale. Older daemons decode to 0.
    public var daemonBuildVersion: Int

    public init(ok: Bool, config: BattlifyConfig, batteryPercent: Int,
                chargingEnabled: Bool, schemeDescription: String,
                lowPowerModeEnabled: Bool = false,
                powerToggles: [String: Bool] = [:],
                pauseReason: String? = nil, magSafeSupported: Bool = false,
                dischargeSupported: Bool = false, discharging: Bool = false,
                message: String? = nil,
                daemonProtocolVersion: Int = ControlProtocol.version,
                daemonBuildVersion: Int = HelperBuild.version) {
        self.ok = ok
        self.config = config
        self.batteryPercent = batteryPercent
        self.chargingEnabled = chargingEnabled
        self.schemeDescription = schemeDescription
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.powerToggles = powerToggles
        self.pauseReason = pauseReason
        self.magSafeSupported = magSafeSupported
        self.dischargeSupported = dischargeSupported
        self.discharging = discharging
        self.message = message
        self.daemonProtocolVersion = daemonProtocolVersion
        self.daemonBuildVersion = daemonBuildVersion
    }

    // Version-tolerant decoding: missing newer fields fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        config = try c.decodeIfPresent(BattlifyConfig.self, forKey: .config) ?? .default
        batteryPercent = try c.decodeIfPresent(Int.self, forKey: .batteryPercent) ?? 0
        chargingEnabled = try c.decodeIfPresent(Bool.self, forKey: .chargingEnabled) ?? false
        schemeDescription = try c.decodeIfPresent(String.self, forKey: .schemeDescription) ?? ""
        lowPowerModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .lowPowerModeEnabled) ?? false
        powerToggles = try c.decodeIfPresent([String: Bool].self, forKey: .powerToggles) ?? [:]
        pauseReason = try c.decodeIfPresent(String.self, forKey: .pauseReason)
        magSafeSupported = try c.decodeIfPresent(Bool.self, forKey: .magSafeSupported) ?? false
        dischargeSupported = try c.decodeIfPresent(Bool.self, forKey: .dischargeSupported) ?? false
        discharging = try c.decodeIfPresent(Bool.self, forKey: .discharging) ?? false
        message = try c.decodeIfPresent(String.self, forKey: .message)
        daemonProtocolVersion = try c.decodeIfPresent(Int.self, forKey: .daemonProtocolVersion) ?? 0
        daemonBuildVersion = try c.decodeIfPresent(Int.self, forKey: .daemonBuildVersion) ?? 0
    }
}

public enum ControlSocket {
    public static let path = "/var/run/battlify.sock"
}

public enum ControlProtocol {
    /// Bumped when the request/response contract gains something the daemon must
    /// understand; the GUI warns when the installed helper reports an older version.
    ///   v2: added `pauseCharging`.
    ///   v3: MagSafe LED mode (Auto/Status/Off) + post-wake settling.
    ///   v4: prepareForSleep, calibrateToFull, prevent-idle-sleep.
    ///   v5: clearSamples (delete the daemon-written history file).
    // Note: the dim-on-battery toggle is a plain additive pmset write — an older
    // helper simply ignores an unknown toggle, so it doesn't warrant a version
    // bump or an "outdated helper" warning.
    public static let version = 5
}

public enum HelperBuild {
    /// Bumped when the daemon's *behaviour* changes enough to warrant updating an
    /// installed helper even though the protocol is unchanged (see `ChargeLimitStore.helperOutdated`).
    ///   v1: gentle 2-min charge-power duty cycle (replaces the 10s toggle that
    ///       flickered the charge indicators), + shutdown/perf hardening.
    ///   v2: fix force-discharge oscillation — gate discharge/LED/keep-awake on
    ///       physical adapter presence (raw SMC AC-W, falling back to IOKit's
    ///       ExternalConnected) instead of the providing-source flag, which flips
    ///       to "battery" while discharging.
    ///   v5: fan boost removed — SMC fan writes are refused on Apple silicon, so an
    ///       installed helper still running the fan policy must be replaced.
    public static let version = 5
}

public enum ControlError: Error, CustomStringConvertible {
    case notConnected          // daemon not running / socket missing
    case ioError(String)
    case decodeError

    public var description: String {
        switch self {
        case .notConnected: return "Battlify helper is not running"
        case .ioError(let s): return "Control I/O error: \(s)"
        case .decodeError: return "Could not decode helper response"
        }
    }
}

/// Synchronous client: connect, send one request, read one response, close.
public enum ControlClient {
    public static func send(_ request: ControlRequest,
                            socketPath: String = ControlSocket.path) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.ioError("socket() failed") }
        defer { close(fd) }

        // Bound send/recv so a wedged daemon can't hang the caller (some call synchronously).
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ControlError.ioError("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ControlError.notConnected }

        var line = try JSONEncoder().encode(request)
        line.append(0x0A) // newline
        try writeAll(fd, line)

        let respData = try readLine(fd)
        guard let resp = try? JSONDecoder().decode(ControlResponse.self, from: respData) else {
            throw ControlError.decodeError
        }
        return resp
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while off < data.count {
                let n = write(fd, base + off, data.count - off)
                if n <= 0 { throw ControlError.ioError("write failed") }
                off += n
            }
        }
    }

    private static func readLine(_ fd: Int32) throws -> Data {
        var out = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n == 0 { break }            // EOF
            if n < 0 { throw ControlError.ioError("read failed") }
            if byte == 0x0A { break }      // newline terminator
            out.append(byte)
        }
        return out
    }
}
