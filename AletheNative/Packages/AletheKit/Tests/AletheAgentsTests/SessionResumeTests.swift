import Foundation
import Testing
@testable import AletheAgents

/// Resume Previous Conversations (P2-26; upstream `resetLastSession` `pickSessionId`).
@Suite struct PreviousSessionTests {
    private let sessions = [
        SessionSnapshot(id: "current", modifiedAt: Date(timeIntervalSince1970: 300)),
        SessionSnapshot(id: "newer", modifiedAt: Date(timeIntervalSince1970: 250)),
        SessionSnapshot(id: "older", modifiedAt: Date(timeIntervalSince1970: 100)),
    ]

    @Test func prefersTheNewestSessionFromBeforeTheCurrentProcess() {
        let pick = SessionResume.previous(in: sessions, excluding: "current", before: Date(timeIntervalSince1970: 200))
        #expect(pick == "older")
    }

    @Test func fallsBackToTheNewestOtherSession() {
        #expect(SessionResume.previous(in: sessions, excluding: "current", before: Date(timeIntervalSince1970: 50)) == "newer")
        #expect(SessionResume.previous(in: sessions, excluding: nil, before: nil) == "current")
    }

    @Test func nothingWhenOnlyTheCurrentOneExists() {
        #expect(SessionResume.previous(in: [sessions[0]], excluding: "current", before: nil) == nil)
    }
}
