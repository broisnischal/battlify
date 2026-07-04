import Foundation
import CoreWLAN

// Private IOBluetooth symbols (exported by IOBluetooth.framework, used by tools
// like blueutil). No public API exists to toggle Bluetooth power.
@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
private func IOBluetoothPreferenceGetControllerPowerState() -> Int32
@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
private func IOBluetoothPreferenceSetControllerPowerState(_ state: Int32)

/// Toggles the system radios. Runs as the user (no root needed).
enum RadioControl {

    // MARK: - Wi-Fi (CoreWLAN, public API)

    static var isWiFiOn: Bool {
        CWWiFiClient.shared().interface()?.powerOn() ?? false
    }

    @discardableResult
    static func setWiFi(_ on: Bool) -> Bool {
        guard let iface = CWWiFiClient.shared().interface() else { return false }
        do {
            try iface.setPower(on)
            return true
        } catch {
            NSLog("Battlify: Wi-Fi setPower(\(on)) failed: \(error)")
            return false
        }
    }

    /// The SSID of the currently-joined Wi-Fi network, or nil if not connected.
    /// On macOS 14+ this returns nil unless the app has Location authorization —
    /// macOS treats the joined SSID as location-revealing.
    static var currentSSID: String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    // MARK: - Bluetooth (private API)

    static var isBluetoothOn: Bool {
        IOBluetoothPreferenceGetControllerPowerState() != 0
    }

    static func setBluetooth(_ on: Bool) {
        IOBluetoothPreferenceSetControllerPowerState(on ? 1 : 0)
    }
}
