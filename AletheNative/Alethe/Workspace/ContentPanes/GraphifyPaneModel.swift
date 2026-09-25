import AletheIntegrations
import Foundation
import Observation

/// One Graphify pane's data (P5-23): the graph read and laid out off the main thread (a newer load
/// cancels the older layout), the snapshots, and the diff against the selected one.
@Observable
@MainActor
final class GraphifyPaneModel {
    enum State: Equatable {
        case loading
        /// No `graphify-out/graph.json` yet.
        case empty
        case failed(String)
        case loaded
    }

    let root: URL
    private(set) var state = State.loading
    private(set) var graph: GraphData?
    private(set) var layout: GraphLayout?
    private(set) var communities: [Int?] = []
    private(set) var snapshots: [GraphSnapshot] = []
    private(set) var comparedSnapshot: String?
    private(set) var diff: GraphDiff?
    /// Node and edge indices the diff marks as added since the compared snapshot.
    private(set) var addedNodes: Set<Int> = []
    private(set) var addedLinks: Set<Int> = []
    /// A snapshot or rollback that failed, shown until the next action.
    private(set) var actionError: String?
    var selectedNode: Int?
    var query = ""
    /// The controller revision last loaded, so a regenerated or rolled back graph reloads.
    private(set) var loadedRevision = 0

    @ObservationIgnored private let controller: GraphifyController
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var layoutWork: Task<GraphLayout, Error>?

    init(root: URL, controller: GraphifyController) {
        self.root = root.standardizedFileURL
        self.controller = controller
        reload()
    }

    var isLayingOut: Bool { state == .loaded && layout == nil }
    var searchResults: [Int] { graph?.search(query) ?? [] }

    var selectedNodeInfo: GraphNode? { selectedNode.flatMap { index in graph?.nodes.indices.contains(index) == true ? graph?.nodes[index] : nil } }

    /// The nodes linked to the selected one, in edge order without repeats.
    var neighbors: [Int] {
        guard let selectedNode, let layout else { return [] }
        var seen = Set<Int>(), result: [Int] = []
        for link in layout.edges {
            let other = link.source == selectedNode ? link.target : link.target == selectedNode ? link.source : nil
            if let other, other != selectedNode, seen.insert(other).inserted { result.append(other) }
        }
        return result
    }

    func reloadIfChanged() {
        if controller.revisions[root, default: 0] != loadedRevision { reload() }
    }

    func reload() {
        generation += 1
        let generation = generation
        loadedRevision = controller.revisions[root, default: 0]
        layoutWork?.cancel()
        layoutWork = nil
        let service = controller.service, root = root
        Task {
            async let snapshots = service.snapshots(root: root)
            let result: Result<GraphData, Error>
            do {
                result = .success(try await service.readGraph(root: root))
            } catch {
                result = .failure(error)
            }
            let list = await snapshots
            guard generation == self.generation else { return }
            self.snapshots = list
            switch result {
            case .success(let graph):
                show(graph, generation: generation)
            case .failure(GraphifyError.graphNotFound):
                clearGraph()
                state = .empty
            case .failure:
                clearGraph()
                state = .failed(String(localized: "graphify.readFailed"))
            }
            if let compared = comparedSnapshot { compare(with: list.contains { $0.id == compared } ? compared : nil) }
        }
    }

    private func clearGraph() {
        graph = nil
        layout = nil
        communities = []
        selectedNode = nil
    }

    private func show(_ graph: GraphData, generation: Int) {
        let previous = selectedNodeInfo?.id
        self.graph = graph
        communities = graph.communityOrdinals
        layout = nil
        selectedNode = previous.flatMap { id in graph.nodes.firstIndex { $0.id == id } }
        state = graph.nodes.isEmpty ? .empty : .loaded
        guard !graph.nodes.isEmpty else { return }
        let work = Task.detached(priority: .userInitiated) { try ForceLayout.compute(graph) }
        layoutWork = work
        Task {
            guard let layout = try? await work.value, generation == self.generation else { return }
            self.layout = layout
            updateHighlights()
        }
    }

    /// Stops a layout still running (the pane closed).
    func cancel() {
        generation += 1
        layoutWork?.cancel()
        layoutWork = nil
    }

    // MARK: - Generation

    var isGenerating: Bool { controller.isGenerating(root) }
    var generationFailure: String? { controller.failures[root] }
    var isAvailable: Bool { controller.executable != nil }

    func generate() {
        Task { await controller.generate(root: root) }
    }

    func cancelGeneration() { controller.cancelGeneration(root: root) }

    // MARK: - Snapshots

    func takeSnapshot() {
        actionError = nil
        Task {
            do {
                _ = try await controller.service.snapshot(root: root)
            } catch {
                actionError = String(localized: "graphify.snapshotFailed")
            }
            snapshots = await controller.service.snapshots(root: root)
        }
    }

    func prune(keepLast: Int) {
        actionError = nil
        Task {
            await controller.service.prune(root: root, keepLast: keepLast)
            snapshots = await controller.service.snapshots(root: root)
            if let compared = comparedSnapshot, !snapshots.contains(where: { $0.id == compared }) { compare(with: nil) }
        }
    }

    /// Highlights what changed from `snapshot` to the current graph; nil stops comparing.
    func compare(with snapshot: String?) {
        comparedSnapshot = snapshot
        guard let snapshot else {
            diff = nil
            updateHighlights()
            return
        }
        let generation = generation
        Task {
            let result = try? await controller.service.diff(root: root, base: snapshot)
            guard generation == self.generation, comparedSnapshot == snapshot else { return }
            diff = result
            updateHighlights()
        }
    }

    /// The caller has asked for confirmation: the current graph is replaced.
    func rollback(to snapshot: String) {
        actionError = nil
        Task {
            do {
                try await controller.rollback(root: root, to: snapshot)
                reloadIfChanged()
            } catch {
                actionError = String(localized: "graphify.rollbackFailed")
            }
        }
    }

    private func updateHighlights() {
        guard let diff, let graph, let layout else {
            addedNodes = []
            addedLinks = []
            return
        }
        addedNodes = Set(graph.nodes.indices.filter { diff.addedNodes.contains(graph.nodes[$0].id) })
        addedLinks = Set(layout.edges.indices.filter { diff.addedEdges.contains(graph.edges[layout.edges[$0].edge].diffKey) })
    }
}
