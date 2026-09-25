import AletheFoundation
import AletheGit
import Foundation
import Observation

/// Commit graph of Git Control (P4-6; upstream `GitGraphList`): paginated log laid out by
/// `GitGraphLayout`, the selected commit's detail and the per-commit actions.
@MainActor @Observable
final class GitHistoryModel {
    static let pageSize = 200

    private(set) var rows: [GitGraphRow] = []
    private(set) var hasMore = true
    private(set) var loading = false
    private(set) var busy = false
    private(set) var error: String? { didSet { if error != oldValue { AppLog.shown(error, .git) } } }
    var selection: String?
    private(set) var detailMessage: String?
    private(set) var detailFiles: [GitFileChange] = []

    private let repository: GitRepository
    /// Called after an action changes the repository, so the Changes tab refreshes too.
    private let onChange: @MainActor () async -> Void
    private var layout = GitGraphLayout()
    private var generation = 0

    init(repository: GitRepository, onChange: @escaping @MainActor () async -> Void) {
        self.repository = repository
        self.onChange = onChange
    }

    /// Reloads from the first page.
    func reload() async {
        generation += 1
        layout = GitGraphLayout()
        rows = []
        hasMore = true
        loading = false
        await loadMore()
    }

    /// Loads the next page; called when the list nears its end.
    func loadMore() async {
        guard hasMore, !loading else { return }
        loading = true
        let current = generation
        do {
            let commits = try await repository.log(skip: rows.count, limit: Self.pageSize)
            guard current == generation else { return }
            let more = commits.count == Self.pageSize
            rows += layout.append(commits, hasMore: more)
            hasMore = more
        } catch {
            guard current == generation else { return }
            self.error = GitControlModel.describe(error)
            hasMore = false
        }
        loading = false
    }

    func select(_ hash: String?) {
        selection = hash
        detailMessage = nil
        detailFiles = []
        guard let hash else { return }
        Task {
            do {
                let message = try await repository.commitMessage(hash)
                let files = try await repository.commitFiles(hash)
                guard selection == hash else { return }
                detailMessage = message
                detailFiles = files
            } catch {
                self.error = GitControlModel.describe(error)
            }
        }
    }

    func cherryPick(_ hash: String) { perform { try await $0.cherryPick(hash) } }
    func revert(_ hash: String) { perform { try await $0.revert(hash) } }
    func reset(_ hash: String, mode: GitResetMode) { perform { try await $0.reset(to: hash, mode: mode) } }
    func branch(_ name: String, at hash: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        perform { try await $0.createBranch(name, atCommit: hash) }
    }

    func dismissError() { error = nil }

    /// Runs one action, then reloads the graph and the Changes state; failures show inline.
    private func perform(_ body: @escaping @Sendable (GitRepository) async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        let repository = repository
        Task {
            do {
                try await body(repository)
            } catch {
                self.error = GitControlModel.describe(error)
            }
            busy = false
            await reload()
            await onChange()
        }
    }
}
