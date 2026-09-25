import Foundation
import Testing
import AletheAgents
import AletheIntegrations
@testable import AletheOrchestrator

// Ported from upstream `src/lib/orchestratorMedia.test.ts` (5 cases; the Windows path is rewritten
// as POSIX) and `src/lib/orchestratorSubagents.test.ts` (2 cases), plus units for the POSIX paths,
// the promoted image and the card readings.

@Suite struct ExtractMediaItemsTests {
    @Test func findsALocalImagePath() {
        #expect(BoardMedia.extract("Saved the chart at /repo/out/chart.png for review.")
            == [MediaItem(kind: .imageLocal, value: "/repo/out/chart.png")])
    }

    @Test func classifiesAnImageURLSeparatelyFromAPlainLink() {
        #expect(BoardMedia.extract("See https://example.com/screenshot.png and also https://example.com/docs for context.") == [
            MediaItem(kind: .imageURL, value: "https://example.com/screenshot.png"),
            MediaItem(kind: .link, value: "https://example.com/docs"),
        ])
    }

    @Test func stripsTrailingPunctuationFromASentence() {
        #expect(BoardMedia.extract("Reference: https://example.com/page.")
            == [MediaItem(kind: .link, value: "https://example.com/page")])
    }

    @Test func deduplicatesAndCapsAtFourItems() {
        let many = (0..<6).map { "https://example.com/page\($0)" }.joined(separator: " ")
        #expect(BoardMedia.extract("\(many) https://example.com/page0").count == 4)
    }

    @Test func returnsNothingForPlainText() {
        #expect(BoardMedia.extract("Read the config files, nothing else to report.") == [])
    }

    // POSIX specifics: a URL's own path, relative paths and non-images never count as local images.
    @Test func matchesOnlyAbsoluteOrHomeImagePaths() {
        let text = "Wrote ~/shots/a.PNG and (/tmp/b.jpeg), not out/c.png, ./d.png or /repo/notes.md; see https://host/e.png"
        #expect(BoardMedia.extract(text) == [
            MediaItem(kind: .imageLocal, value: "~/shots/a.PNG"),
            MediaItem(kind: .imageLocal, value: "/tmp/b.jpeg"),
            MediaItem(kind: .imageURL, value: "https://host/e.png"),
        ])
    }

    @Test func leavesOutALinkAlreadyWrittenAsAMarkdownTarget() {
        #expect(BoardMedia.extract("Read [the docs](https://example.com/docs).") == [])
    }

    @Test func promotesTheFirstImageAndKeepsTheRestForTheStrip() {
        let report = "  See https://example.com/docs, then /repo/a.png and /repo/b.png  "
        #expect(BoardMedia.promoted(report) == MediaItem(kind: .imageLocal, value: "/repo/a.png"))
        #expect(BoardMedia.remaining(report) == [
            MediaItem(kind: .imageLocal, value: "/repo/b.png"),
            MediaItem(kind: .link, value: "https://example.com/docs"),
        ])
        #expect(BoardMedia.promoted("only https://example.com/docs") == nil)
        #expect(BoardMedia.promotedByJobID([
            boardJob("job-01", run: "r", summary: "made /repo/a.png"),
            boardJob("job-02", run: "r", summary: "   "),
        ]) == ["job-01": MediaItem(kind: .imageLocal, value: "/repo/a.png")])
    }
}

private func node(kind: NativeSubagent.Kind = .subagent) -> NativeSubagent {
    NativeSubagent(
        id: "agent-1",
        agentType: "general-purpose",
        kind: kind,
        plannerID: "pty-1",
        sourceAgent: "claude",
        prompt: "Review the code",
        status: .done,
        startedAt: 1,
        endedAt: 2,
        result: "Done"
    )
}

private let cost = SessionCost(byModel: [
    ModelCost(model: "claude-sonnet", input: 10, output: 20, cacheRead: 30, cacheWrite5m: 40, cacheWrite1h: 50, costUSD: 0.015),
])

@Suite struct NativeSubagentJobsTests {
    @Test func attachesTranscriptSpendToNativeAgentJobs() throws {
        let job = try #require(NativeSubagents.jobs([node()], costs: ["agent-1": cost], nowMs: 10).first)
        let expected: OrderedJSON = [
            "totalTokens": 150, "inputTokens": 10, "outputTokens": 20,
            "cachedInputTokens": 30, "cacheCreationInputTokens": 90,
        ]
        #expect(job.tokens?.objectValue?["total"] == expected)
        #expect(job.costUSD == 0.015)
    }

    @Test func doesNotAttributeAgentSpendToBackgroundShells() throws {
        let job = try #require(NativeSubagents.jobs([node(kind: .background)], costs: ["agent-1": cost], nowMs: 10).first)
        #expect(job.tokens == nil)
        #expect(job.costUSD == nil)
    }

    @Test func landsInOneSubagentsRunPerPlannerMarkedNative() throws {
        var running = node()
        running.id = "team:agent-2"
        running.status = .running
        running.endedAt = nil
        running.startedAt = 1_000
        let jobs = NativeSubagents.jobs([node(), running], nowMs: 3_500)
        #expect(jobs.map(\.id) == ["subagent:agent-1", "team:agent-2"])
        #expect(jobs.allSatisfy { $0.runID == "native-subagents:pty-1" && $0.runLabel == "Subagents" && $0.native })
        #expect(jobs.map(\.status) == [.done, .running])
        #expect(jobs.map(\.seconds) == [0, 3])
        #expect(jobs[0].summary == "Done")
        #expect(jobs[1].routing == nil)
    }
}

@Suite struct BoardFormatTests {
    @Test func elapsedReadsSecondsThenMinutes() {
        #expect(BoardFormat.elapsed(nil) == nil)
        #expect(BoardFormat.elapsed(42.9) == "42s")
        #expect(BoardFormat.elapsed(187) == "3m 07s")
        #expect(BoardFormat.elapsed(600) == "10m 00s")
    }

    @Test func tokensShortenLikeToFixed() {
        #expect(BoardFormat.tokens(nil) == nil)
        #expect(BoardFormat.tokens(0) == nil)
        #expect(BoardFormat.tokens(950) == "950")
        #expect(BoardFormat.tokens(1250) == "1.3k")
        #expect(BoardFormat.tokens(1000) == "1.0k")
        #expect(BoardFormat.tokens(9999) == "10.0k")
        #expect(BoardFormat.tokens(42_499) == "42k")
    }

    @Test func contextShareNeedsBothTheTotalAndTheWindow() {
        let job = boardJob("job-01", run: "r", tokens: ["total": ["totalTokens": 50_000], "modelContextWindow": 200_000])
        #expect(BoardFormat.contextShare(job) == 25)
        let over = boardJob("job-02", run: "r", tokens: ["total": ["totalTokens": 300_000], "modelContextWindow": 200_000])
        #expect(BoardFormat.contextShare(over) == 100)
        #expect(BoardFormat.contextShare(boardJob("job-03", run: "r", tokens: ["total": ["totalTokens": 5]])) == nil)
    }

    @Test func latestLineIsTheLastNonBlankOne() {
        #expect(BoardFormat.latestLine("Looking around\n  Fixed the parser  \n\n") == "Fixed the parser")
        #expect(BoardFormat.latestLine("") == "")
    }
}
