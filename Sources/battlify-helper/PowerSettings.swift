import Foundation
import BattlifyKit

/// Reads and writes system sleep/idle power settings via `pmset`. Writing needs
/// root (the daemon has it). These persist system-wide, so they don't need
/// continuous enforcement — set once and macOS remembers.
enum PowerSettings {

    /// Current battery-power values for the keys we expose, parsed from
    /// `pmset -g custom` (the "Battery Power:" section).
    static func readToggles() -> [String: Bool] {
        guard let out = Shell.run("/usr/bin/pmset", ["-g", "custom"]) else { return [:] }
        var result: [String: Bool] = [:]
        var inBatterySection = false
        let wanted = Set(PowerToggle.allCases.map { $0.rawValue })

        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Battery Power:") { inBatterySection = true; continue }
            if line.hasPrefix("AC Power:") { inBatterySection = false; continue }
            guard inBatterySection else { continue }

            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let key = String(parts[parts.count - 2])
            let value = String(parts[parts.count - 1])
            if wanted.contains(key) {
                result[key] = (value == "1")
            }
        }
        return result
    }

    /// Set a toggle for all power sources. Requires root.
    @discardableResult
    static func set(_ toggle: PowerToggle, _ on: Bool) -> Bool {
        Shell.run("/usr/bin/pmset", ["-a", toggle.rawValue, on ? "1" : "0"]) != nil
    }
}
