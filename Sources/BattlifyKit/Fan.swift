import Foundation

/// One fan's live state, as reported by the SMC.
public struct FanState: Sendable, Equatable, Identifiable {
    public let index: Int
    public let rpm: Double
    public let minRPM: Double
    public let maxRPM: Double
    /// True when the fan has been taken off macOS's automatic control — by us, or
    /// by another fan utility. Derived by comparing `F<i>Md` against this Mac's own
    /// resting value, which is not 0 everywhere (see `FanControl.isForced`).
    public let forced: Bool

    public var id: Int { index }

    public init(index: Int, rpm: Double, minRPM: Double, maxRPM: Double, forced: Bool) {
        self.index = index
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.forced = forced
    }

    /// Where the fan currently sits in its own range, 0–100.
    public var percentOfRange: Int {
        guard maxRPM > minRPM else { return 0 }
        let fraction = (rpm - minRPM) / (maxRPM - minRPM)
        return Int((max(0, min(1, fraction)) * 100).rounded())
    }

    /// "Fan 1" / "Fan 2" — the SMC doesn't name them.
    public var title: String { "Fan \(index + 1)" }
}

/// Reads, and as root writes, the SMC fan keys (`FNum`, `F<i>Ac/Mn/Mx/Tg/Md`).
///
/// Deliberately one-directional: nothing here can ask for *less* airflow than the
/// firmware would choose. Forcing a fan slower than macOS wants is how a Mac
/// cooks, so the only write is a boost, it is always clamped into the fan's own
/// [min, max], and forced mode is never engaged before a target is written.
public final class FanControl {
    private let smc: SMC

    /// The `F<i>Md` value each fan reported before anything here wrote to it — this
    /// machine's "macOS is in charge" value. It is *not* 0 everywhere: a Mac15,6
    /// (M3 Pro) rests at 3, so treating nonzero as forced reports idle fans as
    /// hijacked, and restoring a hardcoded 0 leaves them in a mode they never had.
    private var autoMode: [Int: UInt8] = [:]

    /// The value written to `F<i>Md` to take a fan off automatic control.
    static let forcedMode: UInt8 = 1

    public init(smc: SMC) { self.smc = smc }

    /// Whether this Mac exposes controllable fans at all (fanless Macs don't).
    public var isSupported: Bool {
        smc.keyExists("FNum") && smc.keyExists("F0Md")
    }

    public var count: Int {
        guard let value = try? smc.read("FNum"), let first = value.bytes.first else { return 0 }
        return min(Int(first), 8)   // sanity bound; no Mac has eight fans
    }

    public func state(_ index: Int) -> FanState? {
        guard let rpm = float("F\(index)Ac"),
              let low = float("F\(index)Mn"),
              let high = float("F\(index)Mx")
        else { return nil }
        let mode = (try? smc.read("F\(index)Md"))?.bytes.first
        let forced = mode.map { Self.isForced(mode: $0, automatic: automaticMode(index)) } ?? false
        return FanState(index: index, rpm: Double(rpm), minRPM: Double(low),
                        maxRPM: Double(high), forced: forced)
    }

    /// Whether `mode` means the fan is off automatic control, given the resting value
    /// this Mac reported before anything wrote to it.
    ///
    /// `F<i>Md` has no portable "automatic" constant — Intel Macs rest at 0, a Mac15,6
    /// rests at 3 — so anything other than the observed baseline counts as forced, and
    /// our own marker always does even when no baseline was captured.
    static func isForced(mode: UInt8, automatic: UInt8?) -> Bool {
        if mode == forcedMode { return true }
        guard let automatic else { return false }
        return mode != automatic
    }

    /// This fan's resting mode, captured the first time it's read and reused after, so
    /// a boost we applied later can't be mistaken for the baseline. Our own forced
    /// marker is never adopted: a previous run that died without restoring would
    /// otherwise poison the baseline for the life of this process.
    private func automaticMode(_ index: Int) -> UInt8? {
        if let known = autoMode[index] { return known }
        guard let raw = (try? smc.read("F\(index)Md"))?.bytes.first,
              raw != Self.forcedMode else { return nil }
        autoMode[index] = raw
        return raw
    }

    public func states() -> [FanState] {
        (0..<count).compactMap { state($0) }
    }

    /// The RPM a boost percentage maps to within one fan's range. 0 keeps the fan
    /// at its floor — never below it — and 100 is the firmware's own ceiling.
    public static func target(forPercent percent: Int, min low: Double, max high: Double) -> Double {
        let clamped = Swift.max(0, Swift.min(100, percent))
        guard high > low else { return high }
        return (low + (high - low) * Double(clamped) / 100).rounded()
    }

    /// Force every fan to `percent` of its own range. Requires root.
    @discardableResult
    public func boost(toPercent percent: Int) -> Bool {
        let fans = count
        guard fans > 0 else { return false }
        var allOK = true
        for index in 0..<fans {
            guard let fan = state(index) else { allOK = false; continue }
            let target = Self.target(forPercent: percent, min: fan.minRPM, max: fan.maxRPM)
            // Target first, then hand control over, so forced mode can never engage
            // against a stale target from another app or an earlier run.
            guard write(float: Float(target), to: "F\(index)Tg"),
                  write(byte: 1, to: "F\(index)Md")
            else { allOK = false; continue }
        }
        return allOK
    }

    /// Hand every fan back to macOS's own control. Requires root.
    @discardableResult
    public func restoreAuto() -> Bool {
        let fans = count
        guard fans > 0 else { return false }
        var allOK = true
        for index in 0..<fans {
            // Put back what this Mac reported before we touched it. The 0 fallback is
            // only for a fan whose baseline was never captured — leaving it forced is
            // the worse failure, so we still hand it back rather than give up.
            if !write(byte: automaticMode(index) ?? 0, to: "F\(index)Md") { allOK = false }
        }
        return allOK
    }

    // MARK: - SMC value plumbing

    /// Fan RPM keys are 4-byte little-endian IEEE-754 (`flt`).
    private func float(_ key: String) -> Float? {
        guard let value = try? smc.read(key), value.bytes.count >= 4 else { return nil }
        let bits = UInt32(value.bytes[0]) | UInt32(value.bytes[1]) << 8
            | UInt32(value.bytes[2]) << 16 | UInt32(value.bytes[3]) << 24
        return Float(bitPattern: bits)
    }

    private func write(float value: Float, to key: String) -> Bool {
        let bits = value.bitPattern
        let bytes = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                     UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
        return (try? smc.write(key, bytes)) != nil
    }

    private func write(byte: UInt8, to key: String) -> Bool {
        (try? smc.write(key, [byte])) != nil
    }
}
