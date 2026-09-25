import AletheFoundation
import Foundation
import Observation

/// Observable, main-actor owner of one persisted document. Views read `document`; every change goes
/// through `update`, which bumps the revision and schedules a debounced atomic save.
@Observable
@MainActor
public final class DocumentModel<Document: VersionedDocument> {
    public private(set) var document: Document
    public let loadOutcome: DocumentLoadOutcome?
    /// Set when the file belongs to a newer build: the app runs on defaults and never overwrites it.
    public let loadError: DocumentStoreError?

    @ObservationIgnored private let store: DocumentStore<Document>
    @ObservationIgnored private var revision: UInt64 = 0

    private init(store: DocumentStore<Document>, document: Document, outcome: DocumentLoadOutcome?, error: DocumentStoreError?) {
        self.store = store
        self.document = document
        loadOutcome = outcome
        loadError = error
    }

    /// Loads (migrating or recovering as needed). Never fails: problems are reported through
    /// `loadOutcome`/`loadError` and the model starts from the initial document.
    public static func load(from url: URL) async -> DocumentModel {
        let store = DocumentStore<Document>(url: url)
        do {
            let (document, outcome) = try await store.load()
            return DocumentModel(store: store, document: document, outcome: outcome, error: nil)
        } catch let error as DocumentStoreError {
            return DocumentModel(store: store, document: Document.initial, outcome: nil, error: error)
        } catch {
            return DocumentModel(store: store, document: Document.initial, outcome: nil, error: nil)
        }
    }

    /// A change that leaves the document as it was is dropped: observers (the pane host rebuilds
    /// its hosted views) are not woken and nothing is saved.
    public func update(_ body: (inout Document) -> Void) {
        var next = document
        body(&next)
        guard next != document else { return }
        replace(with: next)
    }

    /// An undoable change: ⌘Z restores the document as it was before `body` (and ⇧⌘Z re-applies it).
    public func update(undoManager: UndoManager?, actionName: String, _ body: (inout Document) -> Void) {
        let before = document
        update(body)
        guard document != before else { return }
        registerUndo(undoManager, restoring: before, actionName: actionName)
    }

    private func registerUndo(_ undoManager: UndoManager?, restoring snapshot: Document, actionName: String) {
        guard let undoManager else { return }
        let current = document
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.replace(with: snapshot)
                model.registerUndo(undoManager, restoring: current, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func replace(with next: Document) {
        document = next
        revision += 1
        let snapshot = next
        let revision = revision
        Task { await store.scheduleSave(snapshot, revision: revision) }
    }

    /// Writes pending changes now (quit, profile switch).
    public func flush() async {
        revision += 1
        try? await store.save(document, revision: revision)
    }
}

public typealias WorkspaceModel = DocumentModel<WorkspaceDocument>
public typealias PreferencesModel = DocumentModel<PreferencesDocument>
