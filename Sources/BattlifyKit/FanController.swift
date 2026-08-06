import Foundation

/// One fan's live state, as the SMC reports it.
public struct FanReading: Codable, Sendable, Equatable, Identifiable {
    public let index: Int
    /// Current speed, RPM.
    public let current: Double
    /// The speed range the hardware will accept.
    public let minimum: Double
    public let maximum: Double
    /// The raw `F<i>Md` byte. Its meaning is not portable: 1 is "forced" in the Intel-era
    /// convention, but an M3 Pro reports 3 while macOS is plainly in charge. So it's carried
    /// for display and diagnosis and never used to decide whether a fan is under our control
    /// — that's tracked by whether our own write was accepted.
    public let modeRaw: Int
    /// The target the SMC is aiming for, RPM.
    public let target: Double

    public var id: Int { index }

    /// Two-fan Macs are laid out left and right, and that's what the hardware's own
    /// utilities call them; anything else falls back to numbering.
    public static func name(index: Int, of total: Int) -> String {
        guard total == 2 else { return "Fan \(index + 1)" }
        return index == 0 ? "Left side" : "Right side"
    }

    /// Where `current` sits between min and max, 0…1 — what a UI shows as a level.
    public var fraction: Double {
        guard maximum > minimum else { return 0 }
        return min(1, max(0, (current - minimum) / (maximum - minimum)))
    }
}

/// What the fans should be doing.
public enum FanMode: Codable, Sendable, Equatable {
    /// macOS decides, which is right almost always.
    case auto
    /// Hold a chosen speed, given as a percentage of the hardware's own min…max range.
    case manual(percent: Int)

    public var isManual: Bool { if case .manual = self { return true }; return false }
    public var percent: Int? { if case .manual(let p) = self { return p }; return nil }
}

/// Fan monitoring and control over the SMC.
///
/// The keys are the ones every Mac fan utility uses: `FNum` for the fan count, then per
/// fan `F<i>Ac` (actual RPM), `F<i>Mn`/`F<i>Mx` (the range the hardware accepts),
/// `F<i>Md` (0 = macOS decides, 1 = forced) and `F<i>Tg` (the forced target). Speeds are
/// little-endian `flt` on Apple silicon; the mode byte is `ui8`.
///
/// Two things this type takes seriously, both learned the hard way from a machine found
/// with its fans stuck at 6,800 RPM:
///
///   - **Forced mode outlives the process that set it.** The SMC keeps it across quit,
///     logout and reboot, exactly like the charge inhibit. Anything that forces a fan owes
///     it a restore, so `restoreAuto()` exists and the daemon calls it on shutdown and
///     whenever config says auto but the hardware says forced.
///   - **A target below the hardware minimum is not a quiet Mac, it's an unprotected
///     one.** Requests are clamped into `F<i>Mn…F<i>Mx`, and the daemon layers a thermal
///     guard on top that hands control back to macOS when the machine gets hot.
public final class FanController {
    private let smc: SMC

    public init(smc: SMC) { self.smc = smc }

    /// Number of fans, 0 on a fanless Mac (MacBook Air) or if the key is missing.
    public var count: Int {
        guard let value = try? smc.read("FNum"), let first = value.bytes.first else { return 0 }
        return Int(first)
    }

    public var isSupported: Bool { count > 0 }

    public func readAll() -> [FanReading] {
        (0..<count).compactMap { read(index: $0) }
    }

    public func read(index: Int) -> FanReading? {
        guard let current = float("F\(index)Ac") else { return nil }
        // A fan that doesn't publish a range still reports a speed; treat the range as
        // unknown-but-usable rather than dropping the fan from the list entirely.
        let minimum = float("F\(index)Mn") ?? 0
        let maximum = float("F\(index)Mx") ?? max(current, 1)
        let mode = (try? smc.read("F\(index)Md"))?.bytes.first ?? 0
        return FanReading(index: index, current: Double(current),
                          minimum: Double(minimum), maximum: Double(maximum),
                          modeRaw: Int(mode), target: Double(float("F\(index)Tg") ?? current))
    }

    /// Whether this Mac accepts fan writes at all.
    ///
    /// Not knowable in advance: the keys exist and read fine on machines that refuse every
    /// write, which is exactly what an M3 Pro on macOS 26 does. So it's discovered by trying
    /// once and remembered — retrying a refused write on a timer achieves nothing except log
    /// noise and, if the SMC reacts at all, a fan that stutters between the controller and us.
    public private(set) var writesRefused = false

    /// True when this Mac will actually let the fans be driven.
    public var controlSupported: Bool { isSupported && !writesRefused }

    // MARK: - Control (root only)

    /// Hold every fan at `percent` of its own min…max range.
    ///
    /// Percent rather than RPM because the two fans in a machine don't necessarily share a
    /// range, and "60%" means the same thing on both while "3,000 RPM" might be a crawl for
    /// one and near-max for the other. Target is written before mode, so the fan never sits
    /// in forced mode aiming at a stale target.
    @discardableResult
    public func setManual(percent: Int) -> Bool {
        guard !writesRefused else { return false }
        let clamped = Double(min(100, max(0, percent))) / 100
        var allOK = true
        for fan in readAll() {
            let span = fan.maximum - fan.minimum
            let rpm = fan.minimum + span * clamped
            allOK = write(float: Float(rpm), to: "F\(fan.index)Tg") && allOK
            allOK = write(byte: 1, to: "F\(fan.index)Md") && allOK
        }
        if !allOK { writesRefused = true }
        return allOK
    }

    /// Hand every fan back to macOS. Safe to call when nothing is forced.
    @discardableResult
    public func restoreAuto() -> Bool {
        guard !writesRefused else { return false }
        var allOK = true
        for index in 0..<count {
            allOK = write(byte: 0, to: "F\(index)Md") && allOK
        }
        if !allOK { writesRefused = true }
        return allOK
    }

    // MARK: - Raw access

    private func float(_ key: String) -> Float? {
        guard let value = try? smc.read(key), value.bytes.count >= 4 else { return nil }
        return value.bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
    }

    private func write(float value: Float, to key: String) -> Bool {
        var copy = value
        let bytes = withUnsafeBytes(of: &copy) { Array($0) }
        return (try? smc.write(key, bytes)) != nil
    }

    private func write(byte: UInt8, to key: String) -> Bool {
        (try? smc.write(key, [byte])) != nil
    }
}
