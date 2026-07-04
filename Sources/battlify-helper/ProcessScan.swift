import Foundation

/// Lightweight process inspection for the daemon: is a "keep me awake" task
/// running right now? Runs `ps` (cheap, once per tick) and matches by command
/// name and/or CPU usage. The daemon runs as root, so it sees every user's
/// processes.
enum ProcessScan {
    /// True if any process matches one of `names` (case-insensitive substring of
    /// the command) or, when `minCpu > 0`, uses at least `minCpu` %CPU.
    static func isBusy(names: [String], minCpu: Double) -> Bool {
        let wantNames = names
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !wantNames.isEmpty || minCpu > 0 else { return false }

        guard let out = Shell.run("/bin/ps", ["-Acro", "pid,pcpu,comm"]) else { return false }
        for line in out.split(separator: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let cpu = Double(parts[1]) else { continue }
            let comm = String(parts[2]).lowercased()
            let name = (comm as NSString).lastPathComponent

            if minCpu > 0, cpu >= minCpu { return true }
            if wantNames.contains(where: { name.contains($0) || comm.contains($0) }) {
                return true
            }
        }
        return false
    }
}
