import Foundation
import Testing
@testable import AletheModel

struct ActivityStatsTests {
    private func agent(_ name: String, _ project: String?, _ terminal: String, working: Bool = true) -> ActivitySample.Agent {
        ActivitySample.Agent(agent: name, projectID: project, terminalID: terminal, working: working)
    }

    @Test func parallelTimeKeepsWallClockSeparateFromAgentSum() {
        var day = ActivityTotals()
        day.apply(ActivitySample(date: "2026-06-20", durationMS: 5_000, appFocused: false, userActive: false,
                                 agents: [agent("claude", "x", "a"), agent("codex", "y", "b")]))
        #expect(day.totals.agentWallMs == 5_000)
        #expect(day.totals.agentSumMs == 10_000)
        #expect(day.totals.parallelMs == 5_000)
        #expect(day.totals.peakConcurrent == 2)
        #expect(day.totals.agentBackgroundMs == 5_000)
        #expect(day.agents["claude"]?.backgroundMs == 5_000)
    }

    @Test func focusedAndIdleTime() {
        var day = ActivityTotals()
        day.apply(ActivitySample(date: "2026-06-20", durationMS: 60_000, appFocused: true, userActive: true,
                                 activeProjectID: "p", activeTerminalID: "a",
                                 agents: [agent("claude", "p", "a"), agent("codex", "p", "b", working: false)]))
        day.apply(ActivitySample(date: "2026-06-20", durationMS: 5_000, appFocused: true, userActive: false, activeProjectID: "p"))
        // Capped at 15 s per sample.
        #expect(day.totals.appOpenMs == 20_000)
        #expect(day.totals.userActiveMs == 15_000)
        #expect(day.totals.userIdleMs == 5_000)
        #expect(day.projects["p"]?.focusedMs == 20_000)
        #expect(day.projects["p"]?.agentBackgroundMs == 0)
        #expect(day.agents["claude"]?.focusedMs == 15_000)
        #expect(day.agents["codex"]?.waitingMs == 15_000)
        #expect(day.totals.agentBackgroundMs == 0)
    }

    @Test func summariesAndFile() throws {
        var stats = ActivityStats()
        stats.record([
            ActivitySample(date: "2026-06-20", durationMS: 5_000, appFocused: true, userActive: true),
            ActivitySample(date: "2026-06-21", durationMS: 3_000, appFocused: false, userActive: false),
            ActivitySample(date: "bad", durationMS: 3_000, appFocused: false, userActive: false),
        ])
        #expect(stats.days.count == 2)
        #expect(stats.summary().totals.appOpenMs == 8_000)
        #expect(stats.summary(dates: ["2026-06-21"]).totals.appOpenMs == 3_000)

        let url = FileManager.default.temporaryDirectory.appending(path: "activity-\(UUID().uuidString)/activity-stats.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ActivityStats.append([ActivitySample(date: "2026-06-20", durationMS: 1_000, appFocused: true, userActive: true)], to: url)
        try ActivityStats.append([ActivitySample(date: "2026-06-20", durationMS: 1_000, appFocused: true, userActive: true)], to: url)
        let loaded = try ActivityStats.load(from: url)
        #expect(loaded.days["2026-06-20"]?.totals.appFocusedMs == 2_000)
        // Upstream's camelCase keys.
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("\"appOpenMs\""))
    }

    @Test func days() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_782_950_400) // 2026-07-02 00:00 UTC
        #expect(ActivityStats.lastDays(3, until: now, calendar: calendar) == ["2026-06-30", "2026-07-01", "2026-07-02"])
    }
}
