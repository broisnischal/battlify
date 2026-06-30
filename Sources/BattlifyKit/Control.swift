import Foundation

/// Control protocol between the GUI (client) and the root daemon (server),
/// spoken over a Unix domain socket as newline-delimited JSON.

/// System sleep/idle power features that drain battery while the lid is closed.
/// Raw values are the corresponding `pmset` keys. A value of 1 means the feature
/// is active (and using power); turning it off saves battery during sleep.
public enum PowerToggle: String, Codable, Sendable, CaseIterable {
    case powerNap = "powernap"
    case wakeOnNetwork = "womp"
    case tcpKeepAlive = "tcpkeepalive"

    public var title: String {
        switch self {
        case .powerNap: return "Power Nap"
        case .wakeOnNetwork: return "Wake for network access"
        case .tcpKeepAlive: return "Keep network alive in sleep"
        }
    }

    public var hint: String {
        switch self {
        case .powerNap: return "Wakes periodically while closed to sync Mail/iCloud"
        case .wakeOnNetwork: return "Lets other devices wake this Mac over the network"
        case .tcpKeepAlive: return "Keeps Find My & push active during sleep"
        }
    }
}

public enum ControlRequest: Codable, Sendable {
    case getStatus
    case setConfig(BattlifyConfig)
    case setLowPowerMode(Bool)
    case setPowerToggle(PowerToggle, Bool)
    case applyMode(SaveMode)
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
    /// Why charging is currently paused, if it is: "limit", "heat", or nil.
    public var pauseReason: String?
    public var message: String?

    public init(ok: Bool, config: BattlifyConfig, batteryPercent: Int,
                chargingEnabled: Bool, schemeDescription: String,
                lowPowerModeEnabled: Bool = false,
                powerToggles: [String: Bool] = [:],
                pauseReason: String? = nil, message: String? = nil) {
        self.ok = ok
        self.config = config
        self.batteryPercent = batteryPercent
        self.chargingEnabled = chargingEnabled
        self.schemeDescription = schemeDescription
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.powerToggles = powerToggles
        self.pauseReason = pauseReason
        self.message = message
    }

    // Version-tolerant decoding so GUI/daemon version skew doesn't break the
    // connection (missing newer fields fall back to defaults).
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
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

public enum ControlSocket {
    public static let path = "/var/run/battlify.sock"
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

/// Synchronous client. Connects, sends one request, reads one response, closes.
/// Designed to be called off the main thread.
public enum ControlClient {
    public static func send(_ request: ControlRequest,
                            socketPath: String = ControlSocket.path) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.ioError("socket() failed") }
        defer { close(fd) }

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

        // Send request as one JSON line.
        var line = try JSONEncoder().encode(request)
        line.append(0x0A) // newline
        try writeAll(fd, line)

        // Read response until newline.
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
