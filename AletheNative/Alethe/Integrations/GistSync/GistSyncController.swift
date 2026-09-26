import AletheFoundation
import AletheIntegrations
import AletheModel
import Foundation
import Observation

/// GitHub gist sync in the app (SET-5; upstream `SyncModal` GitHub card) over the profile's
/// `GistSyncService`. Nothing is sent until the user connects and pushes; a pull only stages files
/// until the user confirms (a native gist) or imports it (a Tauri gist).
@Observable
@MainActor
final class GistSyncController {
    enum Action: Equatable {
        case connect, push, pull, disconnect
    }

    enum Notice: Equatable {
        case pushed
    }

    /// Where to create a token with the `gist` scope (upstream `CREATE_TOKEN_URL`).
    static let createTokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=gist&description=Alethe%20Sync")!

    private(set) var status: GistSyncStatus?
    private(set) var busy: Action?
    private(set) var notice: Notice?
    private(set) var error: String?
    /// A validated native pull waiting for the user's confirmation; nothing has changed yet.
    private(set) var confirmingPull: StagedGistPull?
    /// A pulled Tauri gist, shown in the Tauri import sheet.
    private(set) var tauriPull: TauriGistPull?

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var service: GistSyncService?
    @ObservationIgnored private var task: Task<Void, Never>?

    var connected: Bool { status?.connected ?? false }

    func start(environment: AppEnvironment) {
        self.environment = environment
        makeService(session: GistSyncService.makeSession(), apiBase: GistSyncService.defaultAPIBase)
    }

    #if DEBUG
    /// UI tests: a stub GitHub instead of the real one.
    func useEndpoint(session: URLSession, apiBase: URL) {
        makeService(session: session, apiBase: apiBase)
    }
    #endif

    private func makeService(session: URLSession, apiBase: URL) {
        guard let environment, let locations = environment.locations, let profile = environment.profileID else { return }
        service = GistSyncService(profile: profile, locations: locations, secrets: KeychainStore.forLaunch(),
                                  session: session, apiBase: apiBase)
    }

    // MARK: - Actions

    /// Reads the status again (the sheet appearing).
    func refresh() {
        guard let service, busy == nil else { return }
        error = nil
        notice = nil
        task = Task {
            do {
                status = try await service.status()
            } catch {
                self.error = Self.message(for: error)
            }
        }
    }

    func connect(token: String) {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = Self.message(for: GistSyncError.emptyToken)
            return
        }
        run(.connect) { service in
            self.status = try await service.connect(token: token)
        }
    }

    /// Saves the open documents first, so the gist gets what is on screen.
    func push() {
        run(.push) { service in
            await self.environment?.saveDocuments()
            self.status = try await service.push()
            self.notice = .pushed
        }
    }

    /// Downloads and validates the gist without changing anything; a native gist then waits for
    /// `confirmPull`, a Tauri gist goes to the Tauri import sheet.
    func pull() {
        run(.pull) { service in
            switch try await service.pull() {
            case .replacesProfile(let staged):
                self.confirmingPull = staged
            case .tauriImport(let staged):
                self.tauriPull = staged
            }
        }
    }

    /// The one confirmation given: a safety backup, the pull scheduled, and a relaunch.
    func confirmPull() {
        guard let staged = confirmingPull, let environment else { return }
        confirmingPull = nil
        run(.pull) { _ in
            do {
                try await environment.importGistPull(staged)
            } catch {
                self.service?.discard(.replacesProfile(staged))
                throw error
            }
        }
    }

    func cancelPull() {
        guard let staged = confirmingPull else { return }
        confirmingPull = nil
        service?.discard(.replacesProfile(staged))
    }

    /// The Tauri import sheet closed (imported or not): its staged copy is dropped.
    func finishTauriPull() {
        guard let staged = tauriPull else { return }
        tauriPull = nil
        service?.discard(.tauriImport(staged))
    }

    func disconnect() {
        run(.disconnect) { service in
            self.status = try await service.disconnect()
        }
    }

    /// The sheet closed: work in flight stops and an unconfirmed pull is dropped.
    func close() {
        task?.cancel()
        cancelPull()
        finishTauriPull()
    }

    private func run(_ action: Action, _ body: @escaping @MainActor (GistSyncService) async throws -> Void) {
        guard let service, busy == nil else { return }
        busy = action
        error = nil
        notice = nil
        task = Task {
            defer { busy = nil }
            do {
                try await body(service)
            } catch is CancellationError {
            } catch {
                self.error = Self.message(for: error)
            }
        }
    }

    // MARK: - Errors

    /// Upstream's error strings; the token never appears in them.
    static func message(for error: any Error) -> String {
        switch error {
        case let failure as GistSyncError:
            switch failure {
            case .emptyToken: String(localized: "gistSync.error.emptyToken")
            case .invalidToken: String(localized: "gistSync.error.invalidToken")
            case .notConnected: String(localized: "gistSync.error.notConnected")
            case .nothingToSync: String(localized: "gistSync.error.nothingToSync")
            case .noRemote: String(localized: "gistSync.error.noRemote")
            case .remoteMissingWorkspace: String(localized: "gistSync.error.remoteMissingWorkspace")
            case .malformedGist: String(localized: "gistSync.error.malformedGist")
            case .invalidRemoteFile(let name): String(format: String(localized: "gistSync.error.invalidFile"), name)
            case .newerFormat: String(localized: "gistSync.error.newerFormat")
            case .http(let status): String(format: String(localized: "gistSync.error.http"), status)
            case .transport(let code):
                String(format: String(localized: "gistSync.error.generic"),
                       URLError(URLError.Code(rawValue: code)).localizedDescription)
            }
        case let failure as BackupError:
            failure.localizedMessage
        case let failure as ProfileError:
            failure.localizedMessage
        default:
            String(format: String(localized: "gistSync.error.generic"), error.localizedDescription)
        }
    }
}
