import Foundation
import Combine

struct ProcessUsage: Identifiable, Equatable {
    let id: pid_t   // pid
    let name: String
    let cpu: Double  // percent
}

/// Lists the top CPU-consuming processes and can suspend/resume them.
/// Suspend = SIGSTOP, resume = SIGCONT — works for processes owned by this user.
@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var top: [ProcessUsage] = []
    @Published private(set) var suspended: Set<pid_t> = []

    private var timer: Timer?
    private let ownPID = getpid()

    init() {
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        Task.detached {
            let list = Self.sampleTopProcesses(limit: 6)
            await MainActor.run { self.top = list }
        }
    }

    func suspend(_ pid: pid_t) {
        if kill(pid, SIGSTOP) == 0 { suspended.insert(pid) }
    }

    func resume(_ pid: pid_t) {
        if kill(pid, SIGCONT) == 0 { suspended.remove(pid) }
    }

    func toggle(_ usage: ProcessUsage) {
        if suspended.contains(usage.id) { resume(usage.id) } else { suspend(usage.id) }
    }

    /// Parse `ps` output sorted by CPU. Avoids the cost of two rusage samples and
    /// is good enough to surface "what's draining the battery right now".
    private nonisolated static func sampleTopProcesses(limit: Int) -> [ProcessUsage] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -A all, -r sort by CPU, -c command name only, -o custom columns.
        proc.arguments = ["-Acro", "pid,pcpu,comm"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
        var result: [ProcessUsage] = []
        let myPID = getpid()
        for line in text.split(separator: "\n").dropFirst() { // drop header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Split into pid, pcpu, then the rest as the command (may contain spaces).
            let parts = trimmed.split(separator: " ", maxSplits: 2,
                                      omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = pid_t(parts[0]),
                  let cpu = Double(parts[1]) else { continue }
            if pid == myPID { continue }
            let name = String(parts[2])
            // Strip a leading path if ps emitted one.
            let shortName = (name as NSString).lastPathComponent
            result.append(ProcessUsage(id: pid, name: shortName, cpu: cpu))
            if result.count >= limit { break }
        }
        return result
    }
}
