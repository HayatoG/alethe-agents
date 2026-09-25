import Foundation
import SQLite3

/// Home's activity graph (upstream `get_multi_agent_activity`): per UTC day, the Claude Code messages
/// (user and assistant lines of the transcripts), the Codex rollouts last written that day and the
/// OpenCode messages.
public enum ActivityDays {
    public struct Day: Hashable, Sendable {
        public var date: String
        public var count: Int
    }

    public static func collect(days: Int, now: Date = Date(), homeDirectory: String = NSHomeDirectory(),
                               openCodeDatabase: String? = nil) -> [Day] {
        let days = min(max(days, 1), 366)
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        var counts: [String: Int] = [:]
        let files = FileManager.default

        let projects = "\(homeDirectory)/.claude/projects"
        for folder in (try? files.contentsOfDirectory(atPath: projects)) ?? [] {
            let directory = "\(projects)/\(folder)"
            for name in (try? files.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".jsonl") {
                let path = "\(directory)/\(name)"
                if let modified = modified(path), modified < start { continue }
                countClaudeMessages(atPath: path, into: &counts)
            }
        }

        let codex = "\(homeDirectory)/.codex/sessions"
        if let enumerator = files.enumerator(atPath: codex) {
            while let relative = enumerator.nextObject() as? String {
                guard relative.hasSuffix(".jsonl"), let modified = modified("\(codex)/\(relative)"), modified >= start else { continue }
                counts[day(modified), default: 0] += 1
            }
        }

        if let openCodeDatabase { countOpenCodeMessages(database: openCodeDatabase, since: start, into: &counts) }
        return window(days: days, now: now, counts: counts)
    }

    /// The last `days` UTC days, oldest first, with their counts.
    static func window(days: Int, now: Date, counts: [String: Int]) -> [Day] {
        (0..<days).reversed().map { offset in
            let date = day(now.addingTimeInterval(-Double(offset) * 86_400))
            return Day(date: date, count: counts[date] ?? 0)
        }
    }

    /// Consecutive active days ending at the last active one (upstream `computeStreak`).
    public static func streak(_ days: [Day]) -> Int {
        var index = days.count - 1
        while index >= 0, days[index].count == 0 { index -= 1 }
        var streak = 0
        while index >= 0, days[index].count > 0 {
            streak += 1
            index -= 1
        }
        return streak
    }

    static func countClaudeMessages(atPath path: String, into counts: inout [String: Int]) {
        let user = Data(#""type":"user""#.utf8), assistant = Data(#""type":"assistant""#.utf8)
        let stamp = Data(#""timestamp":""#.utf8)
        JSONLReader.forEachLine(atPath: path) { line in
            guard line.range(of: user) != nil || line.range(of: assistant) != nil,
                  let marker = line.range(of: stamp), line.endIndex - marker.upperBound >= 10 else { return true }
            let value = line[marker.upperBound..<(marker.upperBound + 10)]
            // Only the top-level entry type counts; a quick parse settles lines that merely mention one.
            guard let date = String(data: value, encoding: .utf8), date.count == 10,
                  date[date.index(date.startIndex, offsetBy: 4)] == "-", date[date.index(date.startIndex, offsetBy: 7)] == "-",
                  let type = JSONLReader.object(line)?["type"] as? String, type == "user" || type == "assistant" else { return true }
            counts[date, default: 0] += 1
            return true
        }
    }

    static func countOpenCodeMessages(database: String, since start: Date, into counts: inout [String: Int]) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT time_created FROM message WHERE time_created >= ?1", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970 * 1000))
        while sqlite3_step(statement) == SQLITE_ROW {
            counts[day(Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)) / 1000)), default: 0] += 1
        }
    }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
