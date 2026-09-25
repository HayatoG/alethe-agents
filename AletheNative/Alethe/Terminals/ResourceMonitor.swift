import AletheFoundation
import AletheModel
import AletheTerminal
import Dispatch
import Foundation
import Observation

/// Watches memory (upstream `useResourceSupervisor` + `resources.rs`): every 5 s — and at once when
/// macOS reports memory pressure — it measures each terminal's process tree, rates the system's
/// pressure, lowers the priority of terminals kept off screen and, when the user's policy allows,
/// hibernates idle hidden ones.
@Observable
@MainActor
final class ResourceMonitor {
    struct TerminalUsage: Identifiable, Equatable {
        let tab: TabID
        let memoryMB: Double
        var id: TabID { tab }
    }

    private(set) var pressure: MemoryPressure = .normal
    private(set) var system = SystemResources.Memory(totalMB: 0, availableMB: 0)
    private(set) var appMB: Double = 0
    /// Running terminals, largest first.
    private(set) var terminals: [TerminalUsage] = []
    /// Terminals that could be hibernated now under the current policy's idle limits.
    private(set) var candidateCount = 0

    var terminalsMB: Double { terminals.reduce(0) { $0 + $1.memoryMB } }

    static let interval: Duration = .seconds(5)

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var background: Set<TabID> = []
    @ObservationIgnored private var lastUsed: [TabID: Date] = [:]
    /// Pressure level changes so far (upstream `policy_trigger_count`).
    @ObservationIgnored private var pressureChanges = 0
    /// `ResourceMetricsUpdated` after every pass (P6-19).
    @ObservationIgnored private let events = EventOutbox()

    func start(environment: AppEnvironment) {
        guard loop == nil else { return }
        self.environment = environment
        events.attach(environment.multiagent.bus)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: Self.interval)
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        source.resume()
        pressureSource = source
    }

    /// One supervision pass (upstream `run_cycle`).
    func check() {
        guard let environment, let document = environment.workspace?.document else { return }
        let policy = environment.preferences?.document.resources ?? ResourcePolicy()
        let running = environment.terminals.running
        let parents = ProcessTree.currentParents()
        let mounted = document.mountedTabIDs
        let focused = document.workspace.focusedPaneID.flatMap { document.pane($0)?.pane.activeTab?.id }
        let now = Date()
        for tab in mounted { lastUsed[tab] = now }

        var runtimes: [TerminalRuntime] = []
        var usage: [TerminalUsage] = []
        var processCount = 1  // the app, like upstream's walk
        for (tab, view) in running {
            let memory = SystemResources.treeFootprintMB(of: view.processID, parents: parents)
            if view.processID > 0 { processCount += ProcessTree.descendants(of: view.processID, parents: parents).count }
            usage.append(TerminalUsage(tab: tab, memoryMB: memory))
            let quiet = Double(view.quietFor.components.seconds)
            runtimes.append(TerminalRuntime(
                tab: tab, isShell: document.paneHolding(tab)?.pane.tabs.first { $0.id == tab }?.agent == "shell",
                isMounted: mounted.contains(tab), isFocused: tab == focused,
                lastOutput: now.timeIntervalSince1970 - quiet, startedAt: view.startedAt.timeIntervalSince1970,
                lastUsed: (lastUsed[tab] ?? view.startedAt).timeIntervalSince1970, memoryMB: memory))

            // Off-screen terminals run in the background band; shown again, they get full priority.
            let off = !mounted.contains(tab)
            if off != background.contains(tab) {
                SystemResources.setBackground(off, tree: view.processID, parents: parents)
                if off { background.insert(tab) } else { background.remove(tab) }
            }
        }
        background.formIntersection(Set(running.map(\.tab)))

        system = SystemResources.memory()
        appMB = SystemResources.footprintMB(of: getpid())
        let previous = pressure
        pressure = MemoryPressure.level(availableMB: system.availableMB, totalMB: system.totalMB, previous: pressure)
        if pressure != previous { pressureChanges += 1 }
        terminals = usage.sorted { $0.memoryMB > $1.memoryMB }
        let candidates = ResourceSupervision.candidates(runtimes, policy: policy, now: now.timeIntervalSince1970)
        candidateCount = candidates.count
        events.publish(.resourceMetrics(
            memoryPressure: Self.upstreamLevel(pressure), systemAvailableMB: system.availableMB,
            systemTotalMB: system.totalMB, appMB: appMB, ptysMB: terminalsMB, processCount: processCount,
            policyTriggerCount: pressureChanges))

        guard ResourceSupervision.mayHibernate(pressure, policy: policy) else { return }
        // Under pressure one per pass, like upstream; in idle mode every candidate.
        for tab in policy.mode == .idle ? candidates : Array(candidates.prefix(1)) {
            environment.terminals.hibernate(tab)
        }
    }

    /// Upstream's level name for each of the three native levels.
    static func upstreamLevel(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "Ok"
        case .warning: "Medium"
        case .critical: "Critical"
        }
    }
}
