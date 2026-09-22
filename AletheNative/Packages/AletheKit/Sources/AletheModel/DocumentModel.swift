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

    public func update(_ body: (inout Document) -> Void) {
        var next = document
        body(&next)
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
