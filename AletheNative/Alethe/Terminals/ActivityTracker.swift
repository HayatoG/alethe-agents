import AletheAgents
import AletheModel
import AppKit
import Observation

/// Time analytics (upstream `activityTracker.ts` + `activity_stats.rs`): every 5 s a sample of whether
/// Alethe is in front, whether the user is active (input in the last 5 minutes) and what each agent
/// terminal is doing; every 30 s (and when Alethe goes to the background or quits) the samples are
/// added to `activity-stats.json` in the profile.
@Observable
@MainActor
final class ActivityTracker {
    static let sampleInterval: Duration = .seconds(5)
    static let flushInterval: TimeInterval = 30
    static let idleAfter: TimeInterval = 5 * 60

    /// Bumped after every write, so Home reloads its summaries.
    private(set) var revision = 0
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var store: ActivityStore?
    @ObservationIgnored private var pending: [ActivitySample] = []
    @ObservationIgnored private var lastSample = Date()
    @ObservationIgnored private var lastFlush = Date()
    @ObservationIgnored private var lastInteraction = Date()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var monitor: Any?

    func start(environment: AppEnvironment, file: URL) {
        guard loop == nil else { return }
        self.environment = environment
        store = ActivityStore(url: file)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel]) { [weak self] event in
            self?.lastInteraction = Date()
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushNow() }
        }
        lastSample = Date()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                self?.sample()
            }
        }
    }

    func sample(now: Date = Date()) {
        guard let environment, let document = environment.workspace?.document else { return }
        let duration = UInt64(max(0, min(now.timeIntervalSince(lastSample), 15)) * 1000)
        lastSample = now
        guard duration > 0 else { return }
        let focusedPane = document.workspace.focusedPaneID.flatMap { document.pane($0) }
        var agents: [ActivitySample.Agent] = []
        for (tab, _) in environment.terminals.running {
            guard let holder = document.paneHolding(tab),
                  let agent = holder.pane.tabs.first(where: { $0.id == tab })?.agent, agent != "shell" else { continue }
            agents.append(ActivitySample.Agent(agent: agent, projectID: holder.project.id.rawValue, terminalID: tab.rawValue,
                                               working: environment.terminals.activity[tab] == .working))
        }
        pending.append(ActivitySample(
            date: ActivityStats.day(now), durationMS: duration, appFocused: NSApp.isActive,
            userActive: now.timeIntervalSince(lastInteraction) < Self.idleAfter,
            activeProjectID: focusedPane?.project.id.rawValue, activeTerminalID: focusedPane?.pane.activeTab?.id.rawValue,
            agents: agents))
        if now.timeIntervalSince(lastFlush) >= Self.flushInterval { flushNow() }
    }

    /// Writes the pending samples; a failed write keeps the last 360 for the next one.
    func flushNow() {
        guard let store, !pending.isEmpty else { return }
        let batch = pending
        pending = []
        lastFlush = Date()
        Task {
            if await store.append(batch) {
                revision += 1
            } else {
                pending = Array((batch + pending).suffix(360))
            }
        }
    }

    /// Before quitting: the last sample, written before the app exits.
    func finish() async {
        sample()
        guard let store, !pending.isEmpty else { return }
        let batch = pending
        pending = []
        _ = await store.append(batch)
    }

    /// A summary that includes what has not been written yet (upstream flushes before reading).
    func currentSummary(dates: [String]) async -> ActivityTotals {
        sample()
        var summary = await store?.summary(dates: dates) ?? ActivityTotals()
        let filter = Set(dates)
        var unsaved = ActivityTotals()
        for sample in pending where filter.isEmpty || filter.contains(sample.date) { unsaved.apply(sample) }
        summary.add(unsaved)
        return summary
    }

    func summary(dates: [String]) async -> ActivityTotals {
        await store?.summary(dates: dates) ?? ActivityTotals()
    }

    /// Per-day totals for `dates`, in order (Home's activity graph).
    func days(_ dates: [String]) async -> [(date: String, totals: ActivityTotals)] {
        let stats = await store?.stats() ?? ActivityStats()
        return dates.map { ($0, stats.days[$0] ?? ActivityTotals()) }
    }

    func clear() {
        pending = []
        Task {
            await store?.clear()
            revision += 1
        }
    }
}

/// The file, read and written off the main thread one change at a time.
actor ActivityStore {
    let url: URL

    init(url: URL) { self.url = url }

    func append(_ samples: [ActivitySample]) -> Bool {
        (try? ActivityStats.append(samples, to: url)) != nil
    }

    func stats() -> ActivityStats { (try? ActivityStats.load(from: url)) ?? ActivityStats() }

    func summary(dates: [String]) -> ActivityTotals { stats().summary(dates: dates) }

    func clear() { try? FileManager.default.removeItem(at: url) }
}
