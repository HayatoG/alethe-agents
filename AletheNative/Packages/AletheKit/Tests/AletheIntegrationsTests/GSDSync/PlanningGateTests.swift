import Foundation
import Testing
@testable import AletheIntegrations

/// A temporary checkout: a folder with a `.git` entry (no git process needed).
func makeCheckout(_ label: String) -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "AletheGSDTests-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
    return root.resolvingSymlinksInPath()
}

func writeFile(_ root: URL, _ relativePath: String, _ text: String) throws {
    let url = root.appending(path: relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

// Upstream `planning_gate.rs` tests.
@Suite(.timeLimit(.minutes(1))) struct PlanningGateStatusTests {
    @Test func noPlanningFolderMeansNotStarted() {
        let root = makeCheckout("no-planning")
        defer { try? FileManager.default.removeItem(at: root) }
        let status = PlanningGate.status(of: root)
        #expect(!status.hasPlanning)
        #expect(!status.reportedComplete)
    }

    @Test func planningFolderWithoutStatusOrTaskIsIncomplete() throws {
        let root = makeCheckout("empty-planning")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".planning"), withIntermediateDirectories: true)
        let status = PlanningGate.status(of: root)
        #expect(status.hasPlanning)
        #expect(!status.reportedComplete)
    }

    @Test func completeStatusWins() throws {
        let root = makeCheckout("status-complete")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/status.md", "Status: Completed\nProgress: 100%\n")
        let status = PlanningGate.status(of: root)
        #expect(status.reportedComplete)
        #expect(status.progress == 100)
    }

    @Test func statusOverridesConflictingProgress() throws {
        let root = makeCheckout("status-conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/status.md", "Status: In Progress\nProgress: 100%\n")
        #expect(!PlanningGate.status(of: root).reportedComplete)
    }

    @Test func progressAloneDecidesWithoutAStatusLine() throws {
        let root = makeCheckout("progress-only")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/status.md", "Progress: 100%\n")
        #expect(PlanningGate.status(of: root).reportedComplete)
        try writeFile(root, ".planning/status.md", "Progress: 40 %\n")
        let partial = PlanningGate.status(of: root)
        #expect(!partial.reportedComplete)
        #expect(partial.progress == 40)
    }

    @Test func taskFallbackWhenStatusIsMissing() throws {
        let root = makeCheckout("task-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/task.md", "- [x] task 1\n- [x] task 2\n")
        let status = PlanningGate.status(of: root)
        #expect(status.reportedComplete)
        #expect(status.roadmapPendingCount == 0)
        #expect(status.roadmapTotalCount == 2)
    }

    @Test func taskWithPendingItemsIsReportedAndNotComplete() throws {
        let root = makeCheckout("task-pending")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/task.md", "- [x] done 1\n- [ ] pending 1\n- [x] done 2\n- [ ] pending 2\n- [x] done 3\n")
        let status = PlanningGate.status(of: root)
        #expect(!status.reportedComplete)
        #expect(status.roadmapPendingCount == 2)
        #expect(status.roadmapTotalCount == 5)
    }

    @Test func notesComeFromPlan() throws {
        let root = makeCheckout("plan-notes")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/plan.md", "1. Create the file.\n2. Check it exists.\n")
        let notes = try #require(PlanningGate.status(of: root).notes)
        #expect(notes.contains("Create the file"))
        #expect(notes.contains("Check it exists"))
    }

    @Test func notesAreNilWhenPlanIsMissingOrEmpty() throws {
        let root = makeCheckout("plan-no-notes")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/status.md", "Status: Completed\n")
        #expect(PlanningGate.status(of: root).notes == nil)
        try writeFile(root, ".planning/plan.md", "  \n\n")
        #expect(PlanningGate.status(of: root).notes == nil)
    }

    @Test func aLinkedWorktreeResolvesToItselfNotTheMainCheckout() throws {
        let root = makeCheckout("worktree-resolve")
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appending(path: "wt", directoryHint: .isDirectory)
        try writeFile(worktree, ".git", "gitdir: \(root.path)/.git/worktrees/wt\n")
        try writeFile(worktree, ".planning/status.md", "Status: Completed\n")
        try FileManager.default.createDirectory(at: worktree.appending(path: "src/deep"), withIntermediateDirectories: true)

        let mainRoot = try #require(PlanningGate.repositoryRoot(containing: root))
        #expect(!PlanningGate.status(of: mainRoot).hasPlanning)
        let worktreeRoot = try #require(PlanningGate.repositoryRoot(containing: worktree.appending(path: "src/deep")))
        #expect(worktreeRoot.path == worktree.resolvingSymlinksInPath().path)
        #expect(PlanningGate.status(of: worktreeRoot).reportedComplete)
    }

    @Test func noRepositoryRootOutsideACheckout() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AletheGSDTests-none-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The temporary folder is not inside a repository on any sane machine.
        #expect(PlanningGate.repositoryRoot(containing: folder) == nil)
    }
}

@Suite struct PlanningGateParsingTests {
    @Test func roadmapItemsAcceptBulletsAndAnyMark() {
        let items = PlanningGate.roadmapItems("""
        # Roadmap
          - [ ] indented
        * [x] star
        [X] bare
        - [~] other mark
        - [] not an item
        - [ab] not an item
        plain line
        """)
        #expect(items == [
            RoadmapItem(checked: false, text: "indented"),
            RoadmapItem(checked: true, text: "star"),
            RoadmapItem(checked: true, text: "bare"),
            RoadmapItem(checked: true, text: "other mark"),
        ])
    }

    @Test func statusParsingTrimsQuotesAndCase() {
        let parsed = PlanningGate.parseStatus("status: \"DONE\"\nprogress: '75%'\nnote: ignored\n")
        #expect(parsed.status == "done")
        #expect(parsed.progress == 75)
    }

    @Test func outOfRangeProgressIsNoProgress() {
        #expect(PlanningGate.parseStatus("Progress: 300%").progress == nil)
        #expect(PlanningGate.parseStatus("Progress: -1%").progress == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct PlanningGateChildTests {
    @Test func childSessionIsNilWithoutTheSentinel() throws {
        let root = makeCheckout("child-session-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".planning"), withIntermediateDirectories: true)
        #expect(PlanningGate.childSessionID(of: root) == nil)
        try writeFile(root, ".planning/.gsd-child-session", "  \n")
        #expect(PlanningGate.childSessionID(of: root) == nil)
    }

    @Test func childSessionReadsTheTrimmedSentinel() throws {
        let root = makeCheckout("child-session-present")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/.gsd-child-session", "ses_abc123\n")
        #expect(PlanningGate.childSessionID(of: root) == "ses_abc123")
    }

    @Test func busyReflectsTheSentinel() throws {
        let root = makeCheckout("child-busy")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".planning"), withIntermediateDirectories: true)
        #expect(!PlanningGate.childIsBusy(of: root))
        try writeFile(root, ".planning/.gsd-child-busy", "1")
        #expect(PlanningGate.childIsBusy(of: root))
    }

    @Test func errorIsNilWithoutTheSentinel() throws {
        let root = makeCheckout("child-error-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".planning"), withIntermediateDirectories: true)
        #expect(PlanningGate.takeChildError(of: root) == nil)
    }

    @Test func errorIsReadOnceAndConsumed() throws {
        let root = makeCheckout("child-error-present")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/.gsd-child-error", "every model failed\n")
        #expect(PlanningGate.takeChildError(of: root) == "every model failed")
        #expect(PlanningGate.takeChildError(of: root) == nil)
    }

    @Test func childStateReadsAllSentinels() throws {
        let root = makeCheckout("child-state")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/.gsd-child-session", "ses_combined\n")
        try writeFile(root, ".planning/.gsd-child-busy", "1")
        try writeFile(root, ".planning/.gsd-child-error", "model failed\n")
        let state = PlanningGate.childState(of: root)
        #expect(state == GSDChildState(sessionID: "ses_combined", busy: true, error: "model failed"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".planning/.gsd-child-error").path))
    }

    @Test func childStateKeepsTheErrorWithoutASession() throws {
        let root = makeCheckout("child-state-no-session")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/.gsd-child-error", "model failed\n")
        #expect(PlanningGate.childState(of: root) == GSDChildState())
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".planning/.gsd-child-error").path))
    }

    @Test func procedureReadsStepsAndIgnoresInvalidFiles() throws {
        let root = makeCheckout("procedure")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PlanningGate.procedure(of: root).isEmpty)
        try writeFile(root, ".planning/procedure.json", #"[{"description":"Open Settings","category":"ui"}]"#)
        #expect(PlanningGate.procedure(of: root) == [GSDProcedureStep(description: "Open Settings", category: "ui")])
        try writeFile(root, ".planning/procedure.json", "{not json")
        #expect(PlanningGate.procedure(of: root).isEmpty)
    }
}
