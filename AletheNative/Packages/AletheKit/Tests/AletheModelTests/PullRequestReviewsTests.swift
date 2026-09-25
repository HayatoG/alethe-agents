import AletheFoundation
import Foundation
import Testing
@testable import AletheModel

@Suite struct PullRequestReviewsTests {
    @Test func recordForgetAndPreference() {
        var document = PullRequestReviewsDocument.initial
        #expect(document.reviewedHead("o/r#1") == nil)
        document.record("o/r#1", headSHA: " abc123\n", at: Date(timeIntervalSince1970: 1))
        #expect(document.reviewedHead("o/r#1") == "abc123")
        document.record("o/r#1", headSHA: "def456", at: Date(timeIntervalSince1970: 2))
        #expect(document.reviewedHead("o/r#1") == "def456")
        document.record("o/r#2", headSHA: "  ", at: Date(timeIntervalSince1970: 3))
        #expect(document.reviewedHead("o/r#2") == nil)
        document.forget("o/r#1")
        #expect(document.reviews.isEmpty)
        document.setPreference(agent: "codex", model: " gpt-5 ")
        #expect(document.agent == "codex")
        #expect(document.model == "gpt-5")
    }

    @Test func oldestReviewsAreDroppedPastTheLimit() {
        var document = PullRequestReviewsDocument.initial
        for index in 0...PullRequestReviewsDocument.maxEntries {
            document.record("o/r#\(index)", headSHA: "sha\(index)", at: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        #expect(document.reviews.count == PullRequestReviewsDocument.maxEntries)
        #expect(document.reviewedHead("o/r#0") == nil)
        #expect(document.reviewedHead("o/r#\(PullRequestReviewsDocument.maxEntries)") != nil)
    }

    @MainActor @Test func survivesRelaunchThroughTheDocumentStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PullRequestReviewsTests-\(UUID().uuidString)")
            .appending(path: "pull-request-reviews.json")
        let first = await PullRequestReviewsModel.load(from: url)
        #expect(first.document == .initial)
        first.update {
            $0.record("o/r#7", headSHA: "cafe", at: Date(timeIntervalSince1970: 7))
            $0.setPreference(agent: "claude", model: "opus")
        }
        await first.flush()
        let relaunched = await PullRequestReviewsModel.load(from: url)
        #expect(relaunched.document.reviewedHead("o/r#7") == "cafe")
        #expect(relaunched.document.agent == "claude")
        #expect(relaunched.document.model == "opus")
    }

    @Test func profileFileLocation() {
        let locations = DataLocations(root: URL(filePath: "/data", directoryHint: .isDirectory))
        #expect(locations.pullRequestReviews(ProfileID(rawValue: "default")).lastPathComponent == "pull-request-reviews.json")
    }
}
