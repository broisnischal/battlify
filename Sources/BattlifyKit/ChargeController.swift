import Foundation

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

    public init(smc: SMC) {
        self.smc = smc
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
