import Foundation
import Testing
@testable import AletheAgents

struct ActivityDaysTests {
    @Test func streakEndsAtTheLastActiveDay() {
        let days = [3, 0, 2, 5, 0].enumerated().map { ActivityDays.Day(date: "d\($0.offset)", count: $0.element) }
        #expect(ActivityDays.streak(days) == 2)
        #expect(ActivityDays.streak([]) == 0)
    }

    @Test func countsClaudeMessagesPerDay() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "activity-days-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appending(path: ".claude/projects/-tmp-x")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","timestamp":"2026-07-01T10:00:00.000Z","message":{"role":"user"}}"#,
            #"{"type":"assistant","timestamp":"2026-07-01T10:00:05.000Z"}"#,
            #"{"type":"summary","timestamp":"2026-07-01T10:00:06.000Z","note":"\"type\":\"user\""}"#,
            #"{"type":"user","timestamp":"2026-07-02T09:00:00.000Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: folder.appending(path: "s.jsonl"), atomically: true, encoding: .utf8)
        let now = ISO8601DateFormatter().date(from: "2026-07-02T12:00:00Z")!
        let days = ActivityDays.collect(days: 3, now: now, homeDirectory: home.path)
        #expect(days.map(\.date) == ["2026-06-30", "2026-07-01", "2026-07-02"])
        #expect(days.map(\.count) == [0, 2, 1])
    }
}
