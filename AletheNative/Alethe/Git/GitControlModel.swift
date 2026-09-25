import AletheGit
import Foundation
import Observation

/// State of Git Control for one folder (upstream `plugins/git-control`). Git runs in the
/// `GitRepository` actor, off the main thread; a `GitWatcher` refreshes on disk changes.
@MainActor @Observable
final class GitControlModel {
    enum Phase: Equatable {
        case loading
        case notARepository
        case ready
    }

    enum RemoteAction: Equatable {
        case fetch, pull, push
    }

    let folder: URL
    private(set) var phase: Phase = .loading
    private(set) var status: GitStatus?
    private(set) var branches: [GitBranch] = []
    /// Commits ahead of and behind the upstream (P4-7); nil without an upstream.
    private(set) var incomingOutgoing: GitIncomingOutgoing?
    private(set) var error: String?
    /// The remote operation in flight and its last progress line.
    private(set) var remoteAction: RemoteAction?
    private(set) var progress: String?
    private(set) var busy = false
    var message = ""
    var amend = false

    private var repository: GitRepository?
    /// The repository's top level; status paths are relative to it, not to `folder`.
    private(set) var root: URL?
    private var watcher: GitWatcher?
    private var watchTask: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
    }

    /// Discovers the repository, loads it and starts watching.
    func start() async {
        do {
            let root = try await GitRepository.discover(folder)
            let repository = GitRepositories.shared.repository(at: root)
            self.root = root
            self.repository = repository
            watch(root)
            await refresh()
        } catch GitError.notARepository {
            phase = .notARepository
        } catch {
            phase = .notARepository
            self.error = Self.describe(error)
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        watcher?.stop()
        watcher = nil
    }

    private func watch(_ root: URL) {
        stop()
        let watcher = GitWatcher(root: root)
        watcher.start()
        self.watcher = watcher
        watchTask = Task { [weak self] in
            for await _ in watcher.events {
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard let repository else { return }
        do {
            status = try await repository.status()
            branches = (try? await repository.branches())?.filter { !$0.isRemote } ?? []
            incomingOutgoing = try? await repository.incomingOutgoing(limit: 50)
            phase = .ready
        } catch {
            self.error = Self.describe(error)
        }
    }

    func initialize() {
        perform {
            let root = try await GitRepository.initialize(self.folder)
            self.root = root
            self.repository = GitRepositories.shared.repository(at: root)
            self.watch(root)
        }
    }

    func stage(_ paths: [String]) { perform { try await self.repository?.stage(paths) } }
    func stageAll() { perform { try await self.repository?.stageAll() } }
    func unstage(_ paths: [String]) { perform { try await self.repository?.unstage(paths) } }
    func unstageAll() {
        let paths = status?.staged.map(\.path) ?? []
        guard !paths.isEmpty else { return }
        unstage(paths)
    }

    func discard(_ entry: GitStatusEntry) {
        perform { try await self.repository?.discard([entry.path], untracked: entry.isUntracked) }
    }

    func switchBranch(_ name: String) { perform { try await self.repository?.switchBranch(name) } }

    var canCommit: Bool {
        guard !busy, let status else { return false }
        let hasMessage = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return amend || (hasMessage && !status.staged.isEmpty)
    }

    func commit() {
        guard canCommit else { return }
        let message = message
        let amend = amend
        perform {
            try await self.repository?.commit(message: message, amend: amend)
            self.message = ""
            self.amend = false
        }
    }

    func remote(_ action: RemoteAction) {
        guard let repository, remoteAction == nil else { return }
        remoteAction = action
        progress = nil
        error = nil
        let report: @Sendable (String) -> Void = { line in
            Task { @MainActor [weak self] in self?.progress = line }
        }
        Task {
            do {
                switch action {
                case .fetch: _ = try await repository.fetch(onProgress: report)
                case .pull: _ = try await repository.pull(onProgress: report)
                case .push: _ = try await repository.push(onProgress: report)
                }
            } catch {
                self.error = Self.describe(error)
            }
            remoteAction = nil
            progress = nil
            await refresh()
        }
    }

    func dismissError() { error = nil }

    /// Runs one repository change, then refreshes; failures show inline.
    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await body()
            } catch {
                self.error = Self.describe(error)
            }
            busy = false
            await refresh()
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? GitError {
        case .notARepository: String(localized: "git.error.notARepository")
        case .gitMissing: String(localized: "git.error.gitMissing")
        case .commandFailed(_, let stderr): stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        case .cancelled: String(localized: "git.error.cancelled")
        case .invalidArgument(let detail): format("git.error.invalid", detail)
        case nil: error.localizedDescription
        }
    }

    /// A repository-relative path made relative to `folder` (the diff pane runs git there), with `..`
    /// when the project is a subfolder of the repository and the file lies outside it.
    func folderRelativePath(_ repositoryPath: String) -> String {
        guard let root else { return repositoryPath }
        let target = root.appending(path: repositoryPath).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var common = 0
        while common < min(target.count, base.count), target[common] == base[common] { common += 1 }
        let parts = Array(repeating: "..", count: base.count - common) + target[common...]
        return parts.joined(separator: "/")
    }
}
