import Foundation

/// MagSafe / charge-status LED states (SMC key ACLC).
public enum MagSafeLED: UInt8, Sendable {
    case system = 0x00   // macOS controls it (default)
    case off    = 0x01
    case green  = 0x03   // charged / holding at limit
    case orange = 0x04   // charging
}

/// Controls whether the battery is allowed to charge, abstracting over the two
/// SMC schemes Apple Silicon uses:
///   - Pre-Tahoe: 1-byte keys CH0B + CH0C (0x00 = charge, 0x02 = stop)
///   - Tahoe (macOS 26+): 4-byte key CHTE (00 00 00 00 = charge, 01 00 00 00 = stop)
public final class ChargeController {
    private let smc: SMC

    // Key names.
    private let ch0b = "CH0B"
    private let ch0c = "CH0C"
    private let chte = "CHTE"
    private let aclc = "ACLC"   // MagSafe LED
    // Adapter keys (force discharge): legacy CH0I/CH0J, Tahoe CHIE.
    private let ch0i = "CH0I"
    private let ch0j = "CH0J"
    private let chie = "CHIE"

    public init(smc: SMC) {
        self.smc = smc
    }

    // MARK: - Adapter / force discharge
    //
    // Disabling the power adapter makes the Mac run off the battery even while
    // plugged in — i.e. actively discharge. Used to bring the level *down* to the
    // charge limit when you plug in above it.

    private var adapterKey: String? {
        if smc.keyExists(ch0i) { return ch0i }
        if smc.keyExists(ch0j) { return ch0j }
        if smc.keyExists(chie) { return chie }
        return nil
    }

    public var isAdapterControlSupported: Bool { adapterKey != nil }

    /// True when the adapter is supplying power normally (not force-discharging).
    public func isAdapterEnabled() throws -> Bool {
        guard let k = adapterKey else { return true }
        let v = try smc.read(k)
        return v.bytes.first == 0x00
    }

    public func enableAdapter() throws {
        guard let k = adapterKey else { return }
        try smc.write(k, [0x00])
    }

    /// Force discharge by cutting the adapter. CHIE (Tahoe) uses 0x08; others 0x01.
    public func disableAdapter() throws {
        guard let k = adapterKey else { return }
        try smc.write(k, [k == chie ? 0x08 : 0x01])
    }

    // MARK: - MagSafe LED

    /// Whether this Mac has a controllable MagSafe charge LED.
    public var isMagSafeSupported: Bool { smc.keyExists(aclc) }

    public func setMagSafeLED(_ state: MagSafeLED) throws {
        try smc.write(aclc, [state.rawValue])
    }

    /// True when this Mac uses the legacy CH0B/CH0C charging scheme.
    private var usesLegacyKeys: Bool {
        smc.keyExists(ch0b) && smc.keyExists(ch0c)
    }

    public var isChargingControlSupported: Bool {
        smc.keyExists(ch0b) || smc.keyExists(ch0c) || smc.keyExists(chte)
    }

    public func isChargingEnabled() throws -> Bool {
        if usesLegacyKeys {
            let v = try smc.read(ch0b)
            return v.bytes.first == 0x00
        } else {
            let v = try smc.read(chte)
            return v.bytes.prefix(4).allSatisfy { $0 == 0x00 }
        }
    }

    public func enableCharging() throws {
        if usesLegacyKeys {
            try smc.write(ch0b, [0x00])
            try smc.write(ch0c, [0x00])
        } else {
            try smc.write(chte, [0x00, 0x00, 0x00, 0x00])
        }
    }

    public func disableCharging() throws {
        if usesLegacyKeys {
            try smc.write(ch0b, [0x02])
            try smc.write(ch0c, [0x02])
        } else {
            try smc.write(chte, [0x01, 0x00, 0x00, 0x00])
        }
    }

    /// Human-readable description of the scheme in use, for diagnostics.
    public var schemeDescription: String {
        if usesLegacyKeys { return "legacy (CH0B/CH0C)" }
        if smc.keyExists(chte) { return "tahoe (CHTE)" }
        return "unsupported"
    }
}
