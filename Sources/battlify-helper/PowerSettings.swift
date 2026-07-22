import Foundation
import BattlifyKit

/// Reads/writes system sleep/idle settings via `pmset` (writing needs root). These
/// persist system-wide, so set once — no continuous enforcement.
enum PowerSettings {

    /// Current values for the exposed keys, parsed from `pmset -g custom`; each toggle
    /// is read from the section matching its scope (battery/AC).
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

    /// Disable *all* sleep — idle and clamshell — the only way to keep running with the
    /// lid shut (no IOPMAssertion prevents clamshell sleep). Requires root; does NOT
    /// persist across reboots, so the daemon re-applies it on startup.
    @discardableResult
    static func setDisableSleep(_ on: Bool) -> Bool {
        Shell.run("/usr/bin/pmset", ["-a", "disablesleep", on ? "1" : "0"]) != nil
    }

    /// Force the display to sleep now (the keyboard backlight follows). Display sleep is
    /// independent of `disablesleep`, so it works while keep-awake holds the Mac awake with the lid shut.
    @discardableResult
    static func displaySleepNow() -> Bool {
        Shell.run("/usr/bin/pmset", ["displaysleepnow"]) != nil
    }

    /// Put the whole system to sleep now. The caller must first clear `disablesleep`
    /// (otherwise sleep is blocked); used to sleep the Mac once a keep-awake task finishes.
    @discardableResult
    static func sleepNow() -> Bool {
        Shell.run("/usr/bin/pmset", ["sleepnow"]) != nil
    }
}
