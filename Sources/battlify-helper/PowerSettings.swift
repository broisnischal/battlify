import Foundation
import BattlifyKit

/// Reads and writes system sleep/idle power settings via `pmset`. Writing needs
/// root (the daemon has it). These persist system-wide, so they don't need
/// continuous enforcement — set once and macOS remembers.
enum PowerSettings {

    /// Current values for the keys we expose, parsed from `pmset -g custom`.
    /// Each toggle is read from the section that matches its scope (battery-only
    /// toggles like `lessbright` are read from "Battery Power:"; AC-only from
    /// "AC Power:"; all-source toggles from the battery section).
    static func readToggles() -> [String: Bool] {
        guard let out = Shell.run("/usr/bin/pmset", ["-g", "custom"]) else { return [:] }
        var battery: [String: String] = [:]
        var ac: [String: String] = [:]
        var section = 0 // 0 = none, 1 = battery, 2 = AC

        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Battery Power:") { section = 1; continue }
            if line.hasPrefix("AC Power:") { section = 2; continue }
            guard section != 0 else { continue }

            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let key = String(parts[parts.count - 2])
            let value = String(parts[parts.count - 1])
            if section == 1 { battery[key] = value } else { ac[key] = value }
        }

        var result: [String: Bool] = [:]
        for toggle in PowerToggle.allCases {
            let source = toggle.scope == .ac ? ac : battery
            if let value = source[toggle.rawValue] {
                result[toggle.rawValue] = (value == "1")
            }
        }
        return result
    }

    /// Set a toggle on its relevant power source(s). Requires root.
    @discardableResult
    static func set(_ toggle: PowerToggle, _ on: Bool) -> Bool {
        Shell.run("/usr/bin/pmset", [toggle.scope.rawValue, toggle.rawValue, on ? "1" : "0"]) != nil
    }
}
