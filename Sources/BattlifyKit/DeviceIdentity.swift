import Foundation
import CryptoKit
import IOKit

/// Stable per-Mac identifier used to bind a license to one machine.
///
/// The raw IOPlatformUUID survives OS reinstalls and never leaves the machine:
/// what the user sees (and what the storefront signs into the license) is a
/// short code derived from its hash, e.g. "7F3A-92C1-D04B".
public enum DeviceIdentity {
    /// The hardware UUID (IOPlatformUUID) of this Mac, or nil if IOKit fails.
    public static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
    }

    /// Short device code shown to the user and embedded in the license payload,
    /// formatted "XXXX-XXXX-XXXX". Deterministic for a given Mac.
    public static func deviceCode() -> String? {
        guard let uuid = hardwareUUID() else { return nil }
        let digest = SHA256.hash(data: Data("battlify:\(uuid.uppercased())".utf8))
        let hex = digest.prefix(6).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4)
            .map { i -> Substring in
                let s = hex.index(hex.startIndex, offsetBy: i)
                return hex[s..<hex.index(s, offsetBy: 4)]
            }
            .joined(separator: "-")
    }

    /// Canonical form for comparisons: dashes/whitespace stripped, uppercased.
    public static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isHexDigit }
    }
}
