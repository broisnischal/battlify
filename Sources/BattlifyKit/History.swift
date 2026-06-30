import Foundation

/// One periodic battery measurement, stored as a line of JSON in history.jsonl.
public struct BatterySample: Codable, Sendable, Identifiable {
    public var t: Date          // timestamp
    public var pct: Int         // charge %
    public var charging: Bool
    public var temp: Double?    // °C

    public var id: Date { t }

    public init(t: Date, pct: Int, charging: Bool, temp: Double?) {
        self.t = t
        self.pct = pct
        self.charging = charging
        self.temp = temp
    }
}

/// Append-only JSON-lines history store. The daemon appends (it always runs and
/// can write under /Library); the GUI reads.
public enum HistoryStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Append one sample. Best-effort; failures are ignored (history is non-critical).
    public static func append(_ sample: BatterySample,
                              to url: URL = BattlifyPaths.historyFile) {
        guard let data = try? encoder.encode(sample) else { return }
        var line = data
        line.append(0x0A)

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// Load samples newer than `since`. Reads the whole file and filters.
    public static func load(since: Date = .distantPast,
                            from url: URL = BattlifyPaths.historyFile) -> [BatterySample] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [BatterySample] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let sample = try? decoder.decode(BatterySample.self, from: data) else { continue }
            if sample.t >= since { out.append(sample) }
        }
        return out
    }

    /// Trim the file to the most recent `keep` samples, to bound growth.
    public static func trim(keep: Int = 4000, at url: URL = BattlifyPaths.historyFile) {
        let all = load(from: url)
        guard all.count > keep else { return }
        let recent = all.suffix(keep)
        let lines = recent.compactMap { try? encoder.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
        try? (lines + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
