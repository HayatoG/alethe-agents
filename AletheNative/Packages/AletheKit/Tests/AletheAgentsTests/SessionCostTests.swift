import Foundation
import SQLite3
import Testing
@testable import AletheAgents

/// Session cost (P3-8; upstream `agent_cost.rs`).
@Suite struct SessionCostTests {
    private func file(_ lines: [String]) throws -> String {
        let path = FileManager.default.temporaryDirectory.appending(path: "alethe-cost-\(UUID().uuidString).jsonl").path
        try Data(lines.joined(separator: "\n").utf8).write(to: URL(filePath: path))
        return path
    }

    @Test func pricingFollowsTheFamilyTable() throws {
        let sonnet = ModelCost(model: "claude-sonnet-4-5", input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        // 3 + 15 + 0.3 + 3.75 + 6
        #expect(abs((ModelPricing.cost(of: sonnet) ?? 0) - 28.05) < 0.0001)
        #expect(ModelPricing.cost(of: ModelCost(model: "gpt-5", input: 10)) == nil)
    }

    @Test func claudeTranscriptsSumUsagePerModel() throws {
        let path = try file([
            #"{"type":"assistant","message":{"model":"claude-opus-4","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10,"cache_creation":{"ephemeral_5m_input_tokens":5,"ephemeral_1h_input_tokens":7}}}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-4","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3}}}"#,
            #"{"type":"assistant","message":{"model":"claude-haiku-4","usage":{"input_tokens":4,"output_tokens":90}}}"#,
            #"{"type":"user","message":{"content":"no usage here"}}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cost = SessionCosts.claude(transcript: path)
        let opus = try #require(cost.byModel.first { $0.model == "claude-opus-4" })
        #expect(opus.input == 101 && opus.output == 52 && opus.cacheRead == 10 && opus.cacheWrite5m == 8 && opus.cacheWrite1h == 7)
        #expect(cost.model == "claude-haiku-4", "the model with the most output")
        #expect(cost.costUSD != nil)
    }

    @Test func codexTakesTheLastCumulativeCount() throws {
        let path = try file([
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5,"cached_input_tokens":1}}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30,"output_tokens":9,"cached_input_tokens":4}}}}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cost = SessionCosts.codex(rollout: path)
        #expect(cost.input == 30 && cost.output == 9 && cost.cacheRead == 4)
        #expect(cost.costUSD == nil, "Codex has no price in the table")
    }

    @Test func openCodeReadsItsSessionRow() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "alethe-opencode-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE session (id TEXT, model TEXT, tokens_input INTEGER, tokens_output INTEGER,
          tokens_cache_read INTEGER, tokens_cache_write INTEGER, cost REAL);
        INSERT INTO session VALUES ('ses_1', '{"id":"anthropic/claude-sonnet-4"}', 100, 20, 5, 3, 0.42);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let cost = try #require(SessionCosts.openCode(sessionID: "ses_1", database: path))
        #expect(cost.model == "anthropic/claude-sonnet-4")
        #expect(cost.input == 100 && cost.cacheWrite == 3)
        #expect(cost.costUSD == 0.42, "OpenCode's own cost is kept, not repriced")
        #expect(SessionCosts.openCode(sessionID: "missing", database: path) == nil)
    }
}
