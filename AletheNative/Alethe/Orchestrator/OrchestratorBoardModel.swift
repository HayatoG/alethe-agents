import AletheOrchestrator
import Foundation
import Observation

/// One board's state (upstream `OrchestratorPane`'s hooks): the selected planner and worker, the
/// rail's open runs, the view transform, and the groups and layout derived off the main thread from
/// the orchestrator's snapshot plus the planners' subagents. Transforms are in UI points (screen
/// points divided by the UI scale), so the P6-12 fit, zoom and focus math applies unchanged.
@Observable
@MainActor
final class OrchestratorBoardModel {
    private(set) var groups: [PlannerGroup] = []
    private(set) var activeKey: String?
    private(set) var graph = BoardGraph.empty
    /// Promoted image per job id.
    private(set) var media: [String: MediaItem] = [:]
    private(set) var jobsByID: [String: JobSnapshot] = [:]
    private(set) var visibleJobs: [JobSnapshot] = []
    private(set) var view = ViewTransform.identity
    private(set) var selectedWorker: String?
    /// The rail's explicit open/closed choices; runs without one follow `BoardData.opensByDefault`.
    var openRuns: [String: Bool] = [:]
    var summaryOpen = true
    /// Advanced every second while a worker runs, so elapsed times move between snapshots.
    private(set) var now = Date()
    /// When the current snapshot arrived: a running worker's elapsed time counts on from it.
    private(set) var receivedAt = Date()
    /// True once the first derivation landed (the empty state waits for it).
    private(set) var isReady = false

    @ObservationIgnored var reducesMotion = false
    @ObservationIgnored private var source = BoardSource()
    @ObservationIgnored private var selectedPlanner: String?
    @ObservationIgnored private var heights: [String: Double] = [:]
    @ObservationIgnored private var viewport = BoardSize(width: 0, height: 0)
    /// Set by any pan, zoom or focus: from then on new work no longer refits the view.
    @ObservationIgnored private var moved = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var deriving: Task<Void, Never>?
    @ObservationIgnored private var relayoutScheduled = false
    @ObservationIgnored private var animation: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    static let zoomStep = 1.2
    static let liveTick = Duration.seconds(1)

    var activeGroup: PlannerGroup? {
        groups.first { BoardData.key($0) == activeKey } ?? groups.first
    }

    var selectedJob: JobSnapshot? { selectedWorker.flatMap { jobsByID[$0] } }

    // MARK: Input

    func update(_ next: BoardSource) {
        guard next != source else { return }
        source = next
        receivedAt = Date()
        now = receivedAt
        derive()
        let busy = next.jobs.contains { $0.status == .running }
        busy ? startTicking() : stopTicking()
    }

    /// A node's rendered height, in screen points at `unit` screen points per canvas unit. The
    /// layout is redone once per batch of changes, off main.
    func reportHeight(_ id: String, screenHeight: Double, unit: Double) {
        guard unit > 0, screenHeight > 0 else { return }
        let height = screenHeight / unit
        if let known = heights[id], abs(known - height) < 0.5 { return }
        heights[id] = height
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.relayoutScheduled = false
            self.derive()
        }
    }

    /// The canvas size in UI points.
    func setViewport(_ size: BoardSize) {
        guard size != viewport else { return }
        viewport = size
        if !moved { fit(animated: false) }
    }

    private func derive() {
        generation += 1
        let current = generation
        let (source, selected, heights) = (source, selectedPlanner, heights)
        deriving?.cancel()
        deriving = Task { [weak self] in
            let derived = await Task.detached(priority: .userInitiated) {
                BoardData.derive(source, selected: selected, heights: heights)
            }.value
            guard let self, current == self.generation else { return }
            self.apply(derived)
        }
    }

    private func apply(_ derived: BoardDerived) {
        let sizeChanged = derived.graph.size != graph.size || derived.activeKey != activeKey
        if groups != derived.groups { groups = derived.groups }
        if activeKey != derived.activeKey { activeKey = derived.activeKey }
        if graph != derived.graph { graph = derived.graph }
        if media != derived.media { media = derived.media }
        if jobsByID != derived.jobsByID { jobsByID = derived.jobsByID }
        if visibleJobs != derived.visibleJobs { visibleJobs = derived.visibleJobs }
        if let selectedWorker, derived.jobsByID[selectedWorker] == nil { self.selectedWorker = nil }
        isReady = true
        if sizeChanged, !moved { fit(animated: false) }
    }

    // MARK: Selection

    func openPlanner(_ key: String) {
        guard key != activeKey else { return }
        // The tab switches when its layout lands, so the canvas never pairs one planner's runs
        // with another's layout.
        selectedPlanner = key
        selectedWorker = nil
        moved = false
        derive()
    }

    /// A card click: opens the worker's detail, or closes it when it is already open.
    func toggleWorker(_ id: String) {
        selectedWorker = selectedWorker == id ? nil : id
    }

    func clearSelection() {
        selectedWorker = nil
    }

    /// A rail click: selects the worker and brings its card into view.
    func reveal(worker id: String) {
        selectedWorker = id
        focus(nodeID: id)
    }

    func focusSelected() {
        guard let selectedWorker else { return }
        focus(nodeID: selectedWorker)
    }

    func isRunOpen(_ run: BoardRun) -> Bool {
        openRuns[run.id] ?? BoardData.opensByDefault(run)
    }

    func toggleRun(_ run: BoardRun) {
        openRuns[run.id] = !isRunOpen(run)
        guard let tree = graph.trees.first(where: { $0.id == run.id }) else { return }
        moved = true
        setView(BoardLayout.focusView(tree.box, view: view, in: viewport), animated: true)
    }

    // MARK: View transform

    func fit(animated: Bool = true) {
        setView(BoardLayout.fitView(graph.size, in: viewport), animated: animated)
    }

    /// The fit button: fits and lets new work refit again.
    func fitFromButton() {
        moved = false
        fit()
    }

    func zoom(by factor: Double, at point: BoardPoint? = nil, animated: Bool = true) {
        moved = true
        let anchor = point ?? BoardPoint(x: viewport.width / 2, y: viewport.height / 2)
        setView(BoardLayout.zoom(animationTarget, by: factor, at: anchor), animated: animated)
    }

    func pan(by dx: Double, _ dy: Double) {
        moved = true
        animation?.cancel()
        view.x += dx
        view.y += dy
    }

    private func focus(nodeID: String) {
        guard let node = graph.nodes.first(where: { $0.id == nodeID }) else { return }
        moved = true
        setView(BoardLayout.focusView(node.box, view: animationTarget, in: viewport), animated: true)
    }

    /// Where an animation in flight is going, so repeated clicks compound from the end state.
    @ObservationIgnored private var target: ViewTransform?
    private var animationTarget: ViewTransform { target ?? view }

    private func setView(_ next: ViewTransform, animated: Bool) {
        animation?.cancel()
        target = nil
        guard animated, !reducesMotion, next != view else {
            view = next
            return
        }
        let start = view
        target = next
        animation = Task { [weak self] in
            let frames = 12
            for frame in 1...frames {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                let t = Double(frame) / Double(frames)
                let eased = 1 - pow(1 - t, 3)
                self.view = ViewTransform(
                    scale: start.scale + (next.scale - start.scale) * eased,
                    x: start.x + (next.x - start.x) * eased,
                    y: start.y + (next.y - start.y) * eased
                )
            }
            self?.target = nil
        }
    }

    // MARK: Live tick

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.liveTick)
                guard !Task.isCancelled, let self else { return }
                self.now = Date()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    /// A running worker's elapsed seconds as of the last tick.
    func elapsed(_ job: JobSnapshot) -> Double? {
        guard let seconds = job.seconds else { return nil }
        guard job.status == .running else { return seconds }
        return seconds + max(0, now.timeIntervalSince(receivedAt))
    }

    /// The pane is shown again: elapsed times move again while anything runs.
    func resume() {
        if source.jobs.contains(where: { $0.status == .running }) { startTicking() }
    }

    func stop() {
        stopTicking()
        animation?.cancel()
        deriving?.cancel()
    }
}
