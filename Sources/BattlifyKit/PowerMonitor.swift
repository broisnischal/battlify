import Foundation
import IOKit

/// A snapshot of live power flow, in watts.
///
///   adapter ──▶ [ system ]
///           └─▶ [ battery ]   (or battery ──▶ system when unplugged)
///
/// `batteryWatts` is signed: positive = power flowing *into* the battery
/// (charging), negative = flowing *out* (discharging). `systemWatts` is the
/// estimated draw of everything else (SoC, display, peripherals).
public struct PowerFlow: Equatable, Sendable {
    /// Power drawn from the wall adapter (nil when unplugged / unknown).
    public var adapterWatts: Double?
    /// Signed battery power: + charging, − discharging.
    public var batteryWatts: Double
    /// Estimated system consumption (nil if it can't be derived).
    public var systemWatts: Double?
    /// Human label for the adapter, e.g. "96W" (nil when unplugged/unknown).
    public var adapterDescription: String?
    public var isPluggedIn: Bool

    public static let unknown = PowerFlow(
        adapterWatts: nil, batteryWatts: 0, systemWatts: nil,
        adapterDescription: nil, isPluggedIn: false)

    /// Battery power going *into* the pack (0 when discharging).
    public var chargeWatts: Double { max(0, batteryWatts) }
    /// Battery power coming *out* of the pack (0 when charging).
    public var dischargeWatts: Double { max(0, -batteryWatts) }
}

/// Reads instantaneous power flow from the `AppleSmartBattery` IORegistry entry.
/// Read-only — needs no root, so the GUI can poll it directly.
public enum PowerMonitor {

    public static func read() -> PowerFlow {
        var flow = PowerFlow.unknown

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return flow }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0)
            == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any]
        else { return flow }

        flow.isPluggedIn = (props["ExternalConnected"] as? Bool) ?? false

        // Battery instantaneous power: V (mV) × A (mA, signed) → W.
        let voltage = Double((props["Voltage"] as? Int) ?? 0) / 1000.0        // volts
        let amperageRaw = (props["InstantAmperage"] as? Int)
            ?? (props["Amperage"] as? Int) ?? 0
        // Amperage is a signed value packed as unsigned in some firmwares; treat
        // the top bit as sign for 64-bit values.
        let amperage = Double(signedMilliamps(amperageRaw)) / 1000.0          // amps
        flow.batteryWatts = (voltage * amperage)

        // Adapter details (present while plugged in).
        if let adapter = props["AdapterDetails"] as? [String: Any] {
            if let w = adapter["Watts"] as? Int, w > 0 {
                flow.adapterWatts = Double(w)
                flow.adapterDescription = "\(w)W"
            } else if let mv = adapter["AdapterVoltage"] as? Int,
                      let ma = adapter["Current"] as? Int, mv > 0, ma > 0 {
                let w = Double(mv) / 1000.0 * Double(ma) / 1000.0
                flow.adapterWatts = w
                flow.adapterDescription = "\(Int(w.rounded()))W"
            }
            if flow.adapterDescription == nil,
               let name = adapter["Name"] as? String, !name.isEmpty {
                flow.adapterDescription = name
            }
        }

        // System draw ≈ what the adapter delivers minus what goes into the battery.
        // adapter = system + batteryWatts  ⇒  system = adapter − batteryWatts.
        // Unplugged: the battery powers the system, so system = |dischargeWatts|.
        if let adapterW = flow.adapterWatts {
            flow.systemWatts = max(0, adapterW - flow.batteryWatts)
        } else if !flow.isPluggedIn {
            flow.systemWatts = flow.dischargeWatts
        }

        return flow
    }

    /// Interpret a raw amperage integer as signed milliamps. IOKit sometimes
    /// returns the value as a large unsigned integer (two's-complement of a
    /// negative), so fold values above the 32-bit range back to negative.
    private static func signedMilliamps(_ raw: Int) -> Int {
        if raw > Int(Int32.max) { return raw - (1 << 32) }
        return raw
    }
}
