import AletheAgents
import AletheModel
import Foundation
import Observation

/// AI usage of Claude Code, Codex and Antigravity (upstream `*UsageCache.ts`, `limitResetWatch.ts`):
/// fetched every 5 minutes for the providers the user shows, and whenever the AI Usage sheet opens. A
/// window that was at its limit and has reset raises a notification.
@Observable
@MainActor
final class UsageMonitor {
    static let providers: [AgentKind] = [.claude, .codex, .antigravity]
    static let interval: Duration = .seconds(300)

    private(set) var usage: [AgentKind: ProviderUsage] = [:]
    private(set) var refreshing: Set<AgentKind> = []
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var loop: Task<Void, Never>?

    func start(environment: AppEnvironment) {
        self.environment = environment
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self { await self.refresh(self.shownProviders) }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Providers with a toolbar pill (Settings › Agents › Usage). Reading Claude's and Antigravity's
    /// tokens can make macOS ask for Keychain access, so nothing is fetched in the background until the
    /// user turns a pill on.
    var shownProviders: [AgentKind] {
        let shown = Set(environment?.preferences?.document.usagePills ?? [])
        return Self.providers.filter { shown.contains($0.rawValue) }
    }

    func refresh(_ providers: [AgentKind] = UsageMonitor.providers) async {
        guard let environment else { return }
        var jobs: [(AgentKind, String?)] = []
        for provider in providers where !refreshing.contains(provider) {
            refreshing.insert(provider)
            let executable = AgentRegistry.builtin.descriptor(for: provider)?.cliCommand.flatMap {
                environment.launchers.resolve($0, override: environment.preferences?.document.cliPaths?[provider.rawValue])
            }
            jobs.append((provider, executable))
        }
        await withTaskGroup(of: ProviderUsage.self) { group in
            for (provider, executable) in jobs {
                group.addTask { await Self.fetch(provider, executable: executable) }
            }
            for await fresh in group { store(fresh) }
        }
    }

    nonisolated private static func fetch(_ provider: AgentKind, executable: String?) async -> ProviderUsage {
        switch provider {
        case .claude: await AIUsage.claude()
        case .codex: await AIUsage.codex(executable: executable)
        default: await AIUsage.antigravity(executable: executable)
        }
    }

    func consumeResetCredit(_ credit: CodexResetCredit?) async -> Bool {
        guard let environment, let executable = environment.launchers.resolve("codex", override: environment.preferences?.document.cliPaths?["codex"]),
              let fresh = await AIUsage.consumeCodexResetCredit(executable: executable, credit: credit?.id) else { return false }
        store(fresh)
        return true
    }

    private func store(_ fresh: ProviderUsage) {
        refreshing.remove(fresh.agent)
        if let previous = usage[fresh.agent], fresh.status == .ready,
           environment?.preferences?.document.notifyLimitReset != false {
            for window in AIUsage.resets(from: previous, to: fresh) {
                environment?.notifier.post(
                    title: String(format: String(localized: "usage.limitReset"), AgentLabels.name(for: fresh.agent.rawValue)),
                    body: String(format: String(localized: "usage.limitReset.body"), window.label), agent: fresh.agent.rawValue)
            }
        }
        // A failed refresh keeps the last good figures.
        if fresh.status == .ready || usage[fresh.agent]?.status != .ready { usage[fresh.agent] = fresh }
    }
}
