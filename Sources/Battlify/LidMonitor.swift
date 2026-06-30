import Foundation
import IOKit
import IOKit.pwr_mgt

// kIOMessage* are C macros (iokit_common_msg(...)) not exported to Swift.
// These are their well-known constant values from <IOKit/IOMessage.h>.
private let kIOMessageCanSystemSleep: UInt32 = 0xE000_0270
private let kIOMessageSystemWillSleep: UInt32 = 0xE000_0280
private let kIOMessageSystemHasPoweredOn: UInt32 = 0xE000_0300

/// Observes system sleep/wake via IOKit and reports whether a sleep was caused by
/// closing the lid (clamshell). macOS sleeps the Mac when the lid closes on
/// battery, so "lid closed" is detected at the *will-sleep* moment.
final class LidMonitor {
    /// Called just before sleep. `clamshellClosed` is true when the lid is shut.
    var onWillSleep: ((_ clamshellClosed: Bool) -> Void)?
    /// Called after wake.
    var onDidWake: (() -> Void)?

    private var rootPort: io_connect_t = 0
    private var notifierObject: io_object_t = 0
    private var notifyPort: IONotificationPortRef?

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var notifier: io_object_t = 0
        var port: IONotificationPortRef?

        rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let monitor = Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(messageType, messageArgument)
        }, &notifier)

        guard rootPort != 0, let port else {
            NSLog("Battlify: IORegisterForSystemPower failed")
            return
        }
        notifyPort = port
        notifierObject = notifier

        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .commonModes)
    }

    private func handle(_ messageType: natural_t, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case UInt32(kIOMessageCanSystemSleep):
            // Don't veto idle sleep.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))

        case UInt32(kIOMessageSystemWillSleep):
            let closed = Self.isClamshellClosed()
            onWillSleep?(closed)
            // Must acknowledge so sleep can proceed.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))

        case UInt32(kIOMessageSystemHasPoweredOn):
            onDidWake?()

        default:
            break
        }
    }

    /// Reads AppleClamshellState from IOPMrootDomain (true = lid closed).
    static func isClamshellClosed() -> Bool {
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
