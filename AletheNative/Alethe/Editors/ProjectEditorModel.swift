import AletheGit
import AletheModel
import Foundation
import Observation

/// The project editor's background work (P5-5): what the chosen folder holds (a saved Alethe
/// marker, a repository, a stack), Initialize Git, and cloning. File reads and git run off the main
/// thread; everything is cancelable.
@MainActor
@Observable
final class ProjectEditorModel {
    /// What was found in the folder last inspected.
    struct Inspection: Equatable, Sendable {
        var marker: ProjectMarker?
        var isRepository = false
        var stack: StackDetection?
    }

    private(set) var inspection: Inspection?
    private(set) var inspectedFolder: String?
    private(set) var initializing = false
    private(set) var initError: String?

    private(set) var cloning = false
    private(set) var cloneProgress: GitCloneProgress?
    private(set) var cloneError: String?
    private var cloneTask: Task<Void, Never>?

    /// Inspects `folder` after a short pause (typing into the field restarts it); call from `.task(id:)`.
    func inspect(_ folder: String) async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let url = URL(filePath: folder, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard !folder.isEmpty, FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            inspection = nil
            inspectedFolder = nil
            return
        }
        let found = await Task.detached {
            Inspection(marker: ProjectMarker.read(folder: url),
                       isRepository: (try? await GitRepository.discover(url)) != nil,
                       stack: try? ProjectStackDetector.detect(url))
        }.value
        guard !Task.isCancelled else { return }
        inspection = found
        inspectedFolder = folder
        initError = nil
    }

    /// Initialize Git (upstream `git_init`): a first commit of the folder's files.
    func initializeGit(_ folder: String) {
        guard !initializing else { return }
        initializing = true
        initError = nil
        let url = URL(filePath: folder, directoryHint: .isDirectory)
        Task {
            do {
                _ = try await Task.detached { try await GitRepository.initialize(url) }.value
                inspection?.isRepository = true
            } catch {
                initError = NewTerminalSheet.describe(error)
            }
            initializing = false
        }
    }

    /// Clones `url` into `target`; `completion` runs on success only. A failure is shown in the
    /// sheet; a cancel removes the partial folder and leaves the sheet as it was.
    func clone(_ url: String, into target: URL, completion: @escaping @MainActor (URL) -> Void) {
        guard !cloning else { return }
        cloning = true
        cloneError = nil
        cloneProgress = nil
        cloneTask = Task {
            do {
                let cloned = try await GitCloner().clone(url, into: target) { progress in
                    Task { @MainActor in
                        guard self.cloning else { return }
                        self.cloneProgress = progress
                    }
                }
                cloning = false
                completion(cloned)
            } catch {
                cloning = false
                cloneProgress = nil
                if !Self.isCancellation(error) { cloneError = Self.describe(error) }
            }
        }
    }

    func cancelClone() {
        cloneTask?.cancel()
    }

    static func isCancellation(_ error: Error) -> Bool {
        if case GitError.cancelled = error { return true }
        return error is CancellationError
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case GitCloneError.invalidURL:
            String(localized: "editor.problem.cloneURL")
        case GitCloneError.targetExists(let path):
            String(format: String(localized: "editor.clone.targetExists"), path)
        case GitError.gitMissing:
            String(localized: "editor.clone.gitMissing")
        default:
            NewTerminalSheet.describe(error)
        }
    }
}
