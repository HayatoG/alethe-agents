import Foundation
import Testing
@testable import AletheAgents

/// A throwaway home directory holding fixture transcripts.
private struct FixtureHome: ~Copyable {
    let path = FileManager.default.temporaryDirectory.appending(path: "alethe-sessions-\(UUID().uuidString)").path

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func write(_ relative: String, _ contents: String, modified: Date = .now) throws {
        let file = "\(path)/\(relative)"
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file)
    }

    func codexRollout(_ day: String, id: String, cwd: String, modified: Date = .now) throws {
        let meta = #"{"timestamp":"2026-09-23T10:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","originator":"codex_cli_rs","instructions":"\#(String(repeating: "x", count: 100_000))"}}"#
        let message = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#
        try write(".codex/sessions/\(day)/rollout-2026-09-23T10-00-00-\(id).jsonl", meta + "\n" + message + "\n",
                  modified: modified)
    }
}

@Suite struct ClaudeSessionsTests {
    @Test func encodesTheWorkingDirectoryLikeClaudeCode() {
        #expect(ClaudeSessions.projectFolderName(for: "/home/user/repo/.alethe/worktrees/cl-a1b2c3")
            == "-home-user-repo--alethe-worktrees-cl-a1b2c3")
        #expect(ClaudeSessions.projectFolderName(for: "/Users/me/app/") == "-Users-me-app")
        #expect(ClaudeSessions.projectFolderName(for: #"C:\Work\app"#) == "C--Work-app")
    }

    @Test func listsTheFolderTranscriptsNewestFirst() throws {
        let home = FixtureHome()
        try home.write(".claude/projects/-Users-me-app/old.jsonl", "{}\n", modified: .now - 60)
        try home.write(".claude/projects/-Users-me-app/new.jsonl", "{}\n")
        try home.write(".claude/projects/-Users-me-app/notes.txt", "")
        try home.write(".claude/projects/-Users-me-other/elsewhere.jsonl", "{}\n")

        let ids = ClaudeSessions.snapshot(cwd: "/Users/me/app/", homeDirectory: home.path).map(\.id)
        #expect(ids == ["new", "old"])
    }

    @Test func fallsBackToACaseInsensitiveFolderMatch() throws {
        let home = FixtureHome()
        try home.write(".claude/projects/-users-me-app/chat.jsonl", "{}\n")
        #expect(ClaudeSessions.snapshot(cwd: "/Users/me/App", homeDirectory: home.path).map(\.id) == ["chat"])
        #expect(ClaudeSessions.snapshot(cwd: "/Users/me/none", homeDirectory: home.path).isEmpty)
    }
}

@Suite struct CodexSessionsTests {
    @Test func readsSessionMetaOfRolloutsInTheSameFolder() throws {
        let home = FixtureHome()
        try home.codexRollout("2026/09/22", id: "older", cwd: "/Users/me/app", modified: .now - 3600)
        try home.codexRollout("2026/09/23", id: "newer", cwd: "/Users/me/app/")
        try home.codexRollout("2026/09/23", id: "other", cwd: "/Users/me/other")
        try home.write(".codex/sessions/2026/09/23/rollout-broken.jsonl", "not json\n")
        try home.write(".codex/sessions/2026/09/23/rollout-turn.jsonl", #"{"type":"turn_context","payload":{}}"# + "\n")

        let ids = CodexSessions.snapshot(cwd: "/Users/me/app", homeDirectory: home.path).map(\.id)
        #expect(ids == ["newer", "older"])
        #expect(CodexSessions.snapshot(cwd: "", homeDirectory: home.path).isEmpty)
        #expect(CodexSessions.snapshot(cwd: "/Users/me/app", homeDirectory: "/nonexistent").isEmpty)
    }

    @Test func treatsSymlinkedFoldersAsTheSameDirectory() throws {
        let home = FixtureHome()
        let name = "alethe-repo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "/private/tmp/\(name)", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: "/private/tmp/\(name)") }
        try home.codexRollout("2026/09/23", id: "tmp", cwd: "/private/tmp/\(name)")
        #expect(CodexSessions.snapshot(cwd: "/tmp/\(name)", homeDirectory: home.path).map(\.id) == ["tmp"])
    }

    @Test func resumesOnlyAConversationStillOnDisk() throws {
        let home = FixtureHome()
        try home.codexRollout("2026/09/23", id: "kept", cwd: "/Users/me/app")
        #expect(SessionResume.isResumable(.codex, sessionID: "kept", cwd: "/Users/me/app", homeDirectory: home.path))
        #expect(!SessionResume.isResumable(.codex, sessionID: "kept", cwd: "/Users/me/other", homeDirectory: home.path))
        #expect(!SessionResume.isResumable(.codex, sessionID: "gone", cwd: "/Users/me/app", homeDirectory: home.path))
        #expect(!SessionResume.isResumable(.claude, sessionID: "gone", cwd: "/Users/me/app", homeDirectory: home.path))
        #expect(SessionResume.isResumable(.opencode, sessionID: "ses_1", cwd: "/Users/me/app", homeDirectory: home.path))
    }
}

/// Ports of upstream `sessionDiscovery.test.ts`.
@Suite struct SessionClaimsTests {
    private func session(_ id: String, _ seconds: TimeInterval) -> SessionSnapshot {
        SessionSnapshot(id: id, modifiedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func claimsTheOnlyNewSessionAfterTheBeforeSnapshot() {
        var claims = SessionClaims()
        let found = claims.claimDiscovered(.codex, cwd: "/repo", before: ["old"],
                                           sessions: [session("old", 1), session("new", 2)], owner: "tab-1")
        #expect(found?.id == "new")
    }

    @Test func aSecondClaimForTheSameSessionGetsNothing() {
        var claims = SessionClaims()
        let sessions = [session("new", 200), session("old", 50)]
        #expect(claims.claimDiscovered(.codex, cwd: "/repo", before: ["old"], sessions: sessions, owner: "a")?.id == "new")
        #expect(claims.claimDiscovered(.codex, cwd: "/repo", before: ["old"], sessions: sessions, owner: "b") == nil)
    }

    @Test func registeredSessionsAreExcludedFromDiscovery() {
        var claims = SessionClaims()
        claims.register(.codex, cwd: "/repo", sessionID: "assigned", owner: "a")
        let found = claims.claimDiscovered(.codex, cwd: "/repo/", before: [],
                                           sessions: [session("assigned", 1), session("free", 2)], owner: "b")
        #expect(found?.id == "free")
    }

    @Test func ambiguousNewSessionsAreNotClaimed() {
        var claims = SessionClaims()
        let found = claims.claimDiscovered(.codex, cwd: "/repo", before: ["old"],
                                           sessions: [session("old", 1), session("new-a", 2), session("new-b", 3)],
                                           owner: "a")
        #expect(found == nil)
    }

    @Test func aClaimBlocksOtherTabsUntilReleased() {
        var claims = SessionClaims()
        claims.register(.claude, cwd: "/repo/", sessionID: "chat", owner: "tab")
        #expect(claims.isClaimed(.claude, cwd: "/repo", sessionID: "chat", excluding: "other"))
        #expect(!claims.isClaimed(.claude, cwd: "/repo", sessionID: "chat", excluding: "tab"))
        #expect(!claims.isClaimed(.codex, cwd: "/repo", sessionID: "chat"))
        claims.release(owner: "tab")
        #expect(!claims.isClaimed(.claude, cwd: "/repo", sessionID: "chat"))
    }
}

@Suite struct SessionResumeTests {
    @Test func retriesFreshOnlyForAQuickExitOfAResumedAgent() {
        #expect(SessionResume.shouldRetryFresh(resumed: true, elapsed: .seconds(1), alreadyRetried: false))
        #expect(!SessionResume.shouldRetryFresh(resumed: true, elapsed: .seconds(1), alreadyRetried: true))
        #expect(!SessionResume.shouldRetryFresh(resumed: false, elapsed: .seconds(1), alreadyRetried: false))
        #expect(!SessionResume.shouldRetryFresh(resumed: true, elapsed: .seconds(4), alreadyRetried: false))
    }

    @Test func discoveryPollsEveryThreeSecondsThenEveryFifteen() async {
        let waits = Recorder()
        var attempts = 0
        let found = await SessionResume.discover(sleep: { await waits.append($0) }) {
            attempts += 1
            return attempts == 12 ? "rollout" : nil
        }
        #expect(found == "rollout")
        #expect(await waits.values == Array(repeating: .seconds(3), count: 10) + [.seconds(15), .seconds(15)])
    }

    @Test func discoveryStopsWhenCancelled() async {
        let task = Task { await SessionResume.discover(sleep: { _ in await Task.yield() }) { nil } }
        task.cancel()
        #expect(await task.value == nil)
    }
}

private actor Recorder {
    var values: [Duration] = []
    func append(_ value: Duration) { values.append(value) }
}
