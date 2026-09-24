import Foundation
import Observation

/// An open Markdown file (upstream `MarkdownPane` state): read and parsed off the main actor,
/// reloaded when it changes on disk (not while being edited, so an agent writing the file never
/// wipes a draft), edited as source and saved atomically.
@Observable
@MainActor
public final class MarkdownFile {
    public let path: String
    public private(set) var source = ""
    public private(set) var blocks: [MarkdownBlock] = []
    /// Set when the file cannot be read (missing, not UTF-8, not a file).
    public private(set) var loadError: String?
    public private(set) var isLoaded = false
    public private(set) var isEditing = false
    public var draft = ""
    public private(set) var saveError: String?

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var generation = 0

    public var url: URL { URL(filePath: path) }
    public var name: String { url.lastPathComponent }
    public var hasUnsavedChanges: Bool { isEditing && draft != source }

    public init(path: String, watch: Bool = true) {
        self.path = path
        reload()
        if watch { watcher = FileWatcher(path: path) { [weak self] in self?.reload() } }
    }

    /// Stops watching; call when the pane closes.
    public func close() {
        watcher?.stop()
        watcher = nil
    }

    public func reload() {
        generation += 1
        let generation = generation
        let url = url
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(String, [MarkdownBlock]), Error> in
                Result {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    return (text, MarkdownBlocks.parse(text, base: url.deletingLastPathComponent()))
                }
            }.value
            // A newer reload started meanwhile: its result wins.
            guard generation == self.generation else { return }
            switch result {
            case .success(let (text, blocks)):
                source = text
                self.blocks = blocks
                loadError = nil
                if !isEditing { draft = text }
            case .failure(let error):
                loadError = error.localizedDescription
            }
            isLoaded = true
        }
    }

    public func beginEditing() {
        draft = source
        saveError = nil
        isEditing = true
    }

    public func cancelEditing() {
        isEditing = false
        draft = source
        saveError = nil
    }

    /// Writes the draft; the watcher then reloads the rendered view.
    @discardableResult
    public func save() -> Bool {
        do {
            try Data(draft.utf8).write(to: url, options: .atomic)
            source = draft
            blocks = MarkdownBlocks.parse(draft, base: url.deletingLastPathComponent())
            isEditing = false
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}
