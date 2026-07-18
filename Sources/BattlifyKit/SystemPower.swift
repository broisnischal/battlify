import Foundation
import IOKit

/// Small IOKit helpers for system power state, shared by the GUI and daemon.
public enum SystemPower {
    /// Reads `AppleClamshellState` from IOPMrootDomain (true = lid closed).
    /// Returns false if the property is missing (e.g. desktops).
    public static func isClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        else { return false }
        return value
    }
}
