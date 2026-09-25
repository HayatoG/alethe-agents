import AletheFoundation
import Foundation

/// `pull-request-reviews.json` in the profile folder (P4-15): the head SHA each PR was last reviewed
/// at, which guards its squash merge, and the last review agent and model.
public struct PullRequestReviewsDocument: VersionedDocument, Hashable {
    public static let currentVersion = 1
    public static let migrations: [Int: @Sendable (inout JSONObject) throws -> Void] = [:]
    public static let initial = PullRequestReviewsDocument()
    /// Oldest reviews are dropped past this many PRs.
    public static let maxEntries = 200

    public struct Review: Codable, Sendable, Hashable {
        public var headSHA: String
        public var reviewedAt: Date

        public init(headSHA: String, reviewedAt: Date) {
            self.headSHA = headSHA
            self.reviewedAt = reviewedAt
        }
    }

    public var schemaVersion: Int
    /// PR id (`owner/repo#number`) → the review.
    public var reviews: [String: Review]
    /// `AgentKind` raw value of the last review agent; nil before the first review.
    public var agent: String?
    /// The last `--model` value; empty for the agent's default.
    public var model: String

    public init(schemaVersion: Int = currentVersion, reviews: [String: Review] = [:], agent: String? = nil, model: String = "") {
        self.schemaVersion = schemaVersion
        self.reviews = reviews
        self.agent = agent
        self.model = model
    }

    public func reviewedHead(_ pullRequestID: String) -> String? {
        reviews[pullRequestID]?.headSHA
    }

    /// Records a review, keeping at most `maxEntries` (the oldest go first).
    public mutating func record(_ pullRequestID: String, headSHA: String, at date: Date) {
        let sha = headSHA.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pullRequestID.isEmpty, !sha.isEmpty else { return }
        reviews[pullRequestID] = Review(headSHA: sha, reviewedAt: date)
        if reviews.count > Self.maxEntries {
            let dropped = reviews.sorted { $0.value.reviewedAt < $1.value.reviewedAt }.prefix(reviews.count - Self.maxEntries)
            for (id, _) in dropped { reviews[id] = nil }
        }
    }

    public mutating func forget(_ pullRequestID: String) {
        reviews[pullRequestID] = nil
    }

    public mutating func setPreference(agent: String, model: String) {
        self.agent = agent
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public typealias PullRequestReviewsModel = DocumentModel<PullRequestReviewsDocument>
