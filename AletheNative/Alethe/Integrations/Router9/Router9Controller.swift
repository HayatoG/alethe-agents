import AletheFoundation
import AletheIntegrations
import AletheModel
import Foundation
import Observation

/// 9router's runtime in the app (PER-5; upstream `useRouter9Runtime`, `useRouter9AutoStart`): the
/// status the Settings section and the toolbar pill show, start and stop, the API key in the
/// Keychain, install and uninstall through the P3-3 installer, and the one auto-start per launch.
/// Nothing starts unless the user turned 9router and auto-start on; `flush` stops what this app started.
@Observable
@MainActor
final class Router9Controller {
    enum Failure: Equatable {
        case service(Router9Error)
        case keychain
    }

    /// Nil until the first probe finished.
    private(set) var status: Router9Status?
    /// Whether `npm` resolves (the managed install needs it); nil until probed.
    private(set) var hasNPM: Bool?
    private(set) var busy = false
    private(set) var failure: Failure?
    /// Whether the Keychain holds an API key. The key itself is never kept in observable state.
    private(set) var hasAPIKey = false

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private(set) var service: Router9Service?
    @ObservationIgnored private var profile: String?
    @ObservationIgnored private var secrets: any SecretStore = KeychainStore.forLaunch()
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    static let installTool = "router9"

    var preferences: Router9Preferences { environment?.preferences?.document.router9Settings ?? Router9Preferences() }
    var hasInstall: Bool { Router9.hasInstall(status) }
    var isRunning: Bool { status?.running == true }
    var resolved: (source: AletheIntegrations.Router9Source, install: Router9Install)? {
        Router9.resolveSource(status, preferred: AletheIntegrations.Router9Source(preferences.source))
    }

    func start(environment: AppEnvironment) {
        self.environment = environment
        guard let locations = environment.locations, let profileID = environment.profileID else { return }
        profile = profileID.rawValue
        service = Router9Service(profileDirectory: locations.profileDirectory(profileID),
                                 dependencies: .live(launchers: environment.launchers))
        loadKeyPresence()
        autoStart()
    }

    /// Stops the process this app started (quit, and when 9router is turned off).
    func stop() async {
        refreshing?.cancel()
        await service?.stop()
    }

    // MARK: Status

    /// Re-reads installs, the port and the toolchain. Concurrent callers share one probe.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        guard let service, let environment else { return }
        let port = preferences.port, launchers = environment.launchers
        let task = Task {
            async let next = service.status(port: port)
            async let npm = Task.detached { launchers.resolve("npm") != nil }.value
            let (status, hasNPM) = await (next, npm)
            self.status = status
            self.hasNPM = hasNPM
        }
        refreshing = task
        await task.value
        refreshing = nil
    }

    /// While a view showing the status is on screen: a full probe now, then a cheap liveness check
    /// every few seconds that probes again only when the process started or ended. Ends when the
    /// calling view's task is cancelled.
    func watch() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let service else { return }
            if service.isRunning != isRunning { await refresh() }
        }
    }

    // MARK: Start and stop

    func toggleRunning() async {
        if isRunning { await stopRouter() } else { await startRouter() }
    }

    func startRouter() async {
        guard let service, !busy else { return }
        busy = true
        failure = nil
        let preferences = preferences
        let source = resolved?.source ?? AletheIntegrations.Router9Source(preferences.source)
        do throws(Router9Error) {
            try await service.start(port: preferences.port, source: source)
        } catch {
            failure = .service(error)
        }
        busy = false
        await refresh()
    }

    func stopRouter() async {
        guard let service, !busy else { return }
        busy = true
        await service.stop()
        busy = false
        await refresh()
    }

    /// Upstream `useRouter9AutoStart`: once per launch, only when the user asked for it.
    private func autoStart() {
        guard Router9.wantsAutoStart(preferences), let service else { return }
        Task {
            let preferences = preferences
            let status = await service.status(port: preferences.port)
            self.status = status
            guard let source = Router9.autoStartSource(preferences, status: status) else { return }
            do throws(Router9Error) {
                try await service.start(port: preferences.port, source: source)
            } catch {
                failure = .service(error)
            }
            await refresh()
        }
    }

    // MARK: Preferences

    func update(_ change: (inout Router9Preferences) -> Void) {
        let before = preferences
        environment?.preferences?.update { document in
            var settings = document.router9Settings
            change(&settings)
            document.router9 = settings
        }
        let after = preferences
        if before.enabled, !after.enabled { Task { await stopRouter() } }
        if before.port != after.port { Task { await refresh() } }
    }

    // MARK: API key (Keychain only; never logged, never read back into the UI)

    func saveAPIKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profile, !key.isEmpty else { return }
        writeKey(key, profile: profile)
    }

    func removeAPIKey() {
        guard let profile else { return }
        writeKey("", profile: profile)
    }

    /// Routing inputs for new terminals (P7-17): nil when 9router is off or has no key.
    func routingConfig() async -> Router9RoutingConfig? {
        let preferences = preferences
        guard preferences.enabled, let profile else { return nil }
        let secrets = secrets
        let key = await Task.detached { try? secrets.string(for: .router9APIKey, profile: profile) }.value ?? nil
        guard let key, !key.isEmpty else { return nil }
        return Router9RoutingConfig(preferences, apiKey: key)
    }

    private func writeKey(_ key: String, profile: String) {
        let secrets = secrets
        Task {
            let saved = await Task.detached {
                (try? secrets.setString(key, for: .router9APIKey, profile: profile)) != nil
            }.value
            if saved {
                hasAPIKey = !key.isEmpty
                if failure == .keychain { failure = nil }
            } else {
                failure = .keychain
            }
        }
    }

    private func loadKeyPresence() {
        guard let profile else { return }
        let secrets = secrets
        Task {
            hasAPIKey = await Task.detached {
                ((try? secrets.data(for: .router9APIKey, profile: profile)) ?? nil)?.isEmpty == false
            }.value
        }
    }

    // MARK: Install and uninstall

    enum InstallAction: String, Identifiable {
        case install, uninstall
        var id: Self { self }
    }

    /// The exact command line the sheet shows and runs.
    func command(for action: InstallAction) async -> String? {
        guard let service else { return nil }
        switch action {
        case .install:
            do throws(Router9Error) { return try await service.installCommand() } catch {
                failure = .service(error)
                return nil
            }
        case .uninstall:
            return service.uninstallCommand()
        }
    }

    /// Runs `command` through the shared installer; success is what is on disk afterwards, not npm's
    /// exit status (upstream `useRouter9Install`).
    func run(_ action: InstallAction, command: String) async {
        guard let environment, let service else { return }
        // Removing the package under a live process would leave an orphan holding the port.
        if action == .uninstall { await service.stop() }
        await environment.installer.run(command: command, tool: Self.installTool) {
            let status = await service.status(port: self.preferences.port)
            return action == .install ? status.managed.installed : !status.managed.installed
        }
        environment.launchers.invalidate()
        await refresh()
    }

    #if DEBUG
    /// UI tests: a service over stubbed system calls instead of the real `node` and `9router`.
    func useStubService(_ dependencies: Router9Dependencies) {
        guard let locations = environment?.locations, let profileID = environment?.profileID else { return }
        service = Router9Service(profileDirectory: locations.profileDirectory(profileID), dependencies: dependencies)
        Task { await refresh() }
    }

    /// UI tests: the store the seeds write to.
    var secretStore: any SecretStore { secrets }
    #endif
}
