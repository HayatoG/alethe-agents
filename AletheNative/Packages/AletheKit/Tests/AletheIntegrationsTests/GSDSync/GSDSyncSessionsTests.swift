import Foundation
import Testing
@testable import AletheIntegrations

@Suite(.timeLimit(.minutes(1))) struct GSDSyncSessionsTests {
    @Test func readsChildSessionsWithTheirPlanningStatus() async throws {
        let root = makeCheckout("sessions")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/.gsd-child-session", "ses_child\n")
        try writeFile(root, ".planning/.gsd-child-busy", "")
        try writeFile(root, ".planning/task.md", "- [x] one\n- [ ] two\n- [ ] three\n")
        let service = GSDSyncService(profileDirectory: root.appending(path: "profile"))

        let sessions = await service.sessions(for: [GSDSyncTarget(projectID: "p1", directory: root)])
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.childID == "ses_child")
        #expect(session.busy)
        #expect(session.error == nil)
        #expect(session.roadmapProgress?.done == 1)
        #expect(session.roadmapProgress?.total == 3)
        #expect(session.name == root.lastPathComponent)
    }

    @Test func checkoutsWithoutAChildSessionAreLeftOut() async {
        let root = makeCheckout("no-child")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appending(path: "AletheGSDTests-outside-\(UUID().uuidString)")
        let service = GSDSyncService(profileDirectory: root.appending(path: "profile"))
        let sessions = await service.sessions(for: [
            GSDSyncTarget(projectID: "p1", directory: root),
            GSDSyncTarget(projectID: "p1", directory: outside),
        ])
        #expect(sessions.isEmpty)
    }

    @Test func oneReadPerProjectCheckoutAndTheErrorIsReportedOnce() async throws {
        let root = makeCheckout("dedupe")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, ".planning/.gsd-child-session", "ses_child")
        try writeFile(root, ".planning/.gsd-child-error", "rate limited")
        let sub = root.appending(path: "src")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let service = GSDSyncService(profileDirectory: root.appending(path: "profile"))

        let first = await service.sessions(for: [
            GSDSyncTarget(projectID: "p1", directory: root),
            GSDSyncTarget(projectID: "p1", directory: sub),
            GSDSyncTarget(projectID: "p2", directory: root),
        ])
        try #require(first.map(\.projectID) == ["p1", "p2"])
        #expect(first[0].error == "rate limited")
        #expect(first[1].error == nil, "consumed by the first read")

        let second = await service.sessions(for: [GSDSyncTarget(projectID: "p1", directory: root)])
        #expect(second.first?.error == nil)
    }

    @Test func roadmapProgressNeedsAChecklist() {
        let session = GSDSyncSession(projectID: "p", root: URL(filePath: "/tmp/x"), childID: "c", busy: false, error: nil,
                                     planning: PlanningStatus(hasPlanning: true, progress: 40))
        #expect(session.roadmapProgress == nil)
    }
}
