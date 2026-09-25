import Foundation
import AletheIntegrations

/// The board canvas layout (upstream `lib/orchestratorGraph.ts`): one tree per run, the planner over
/// its runs, each run over one row of its workers, a worker's promoted image in a card below it.
/// Coordinates are canvas points; the view only draws what this returns.
public enum BoardLayout {
    public static let nodeWidth: Double = 252
    public static let siblingGap: Double = 24
    public static let treeGap: Double = 120
    public static let levelGap: Double = 56
    public static let canvasPadding: Double = 40
    public static let defaultNodeHeight: Double = 76
    public static let elbowRadius: Double = 8
    public static let dotSpacing: Double = 22
    public static let minScale: Double = 0.35
    public static let maxScale: Double = 1.6

    public static func rootNodeID(_ runID: String) -> String { "run:" + runID }
    public static func plannerNodeID(_ plannerID: String) -> String { "planner:" + plannerID }
    /// A worker's promoted image gets one card, directly below it.
    public static func mediaNodeID(_ jobID: String) -> String { jobID + ":media" }

    /// Upstream `layoutPlannerBoard`. `heights` holds measured card heights by node id; anything not
    /// measured yet is `defaultNodeHeight`. The backend reports no relation between workers, so the
    /// only edges are planner → run, run → worker and worker → its media card.
    public static func layout(
        runs: [BoardRun],
        heights: [String: Double] = [:],
        plannerID: String? = nil,
        mediaByJobID: [String: MediaItem] = [:]
    ) -> BoardGraph {
        guard !runs.isEmpty else { return .empty }

        func height(_ id: String) -> Double {
            if let measured = heights[id], measured > 0 { return jsRound(measured) }
            return defaultNodeHeight
        }

        let spans = runs.map { run -> Double in
            let count = Double(run.jobs.count)
            return run.jobs.isEmpty ? nodeWidth : count * nodeWidth + (count - 1) * siblingGap
        }
        var lefts: [Double] = []
        var cursor = canvasPadding
        for span in spans {
            lefts.append(cursor)
            cursor += span + treeGap
        }

        let plannerHeight = plannerID.map { height(plannerNodeID($0)) } ?? 0
        let runTop = canvasPadding + (plannerID != nil ? plannerHeight + levelGap : 0)
        let runHeights = runs.map { height(rootNodeID($0.id)) }
        // Every worker in the forest shares one baseline, so the levels read as levels.
        let workerTop = runTop + (runHeights.max() ?? 0) + levelGap

        let roots = runs.indices.map { index in
            GraphNode(
                id: rootNodeID(runs[index].id),
                kind: .run,
                depth: plannerID != nil ? 1 : 0,
                index: index,
                x: jsRound(lefts[index] + (spans[index] - nodeWidth) / 2),
                y: runTop,
                width: nodeWidth,
                height: runHeights[index]
            )
        }

        var workers: [GraphNode] = []
        var media: [GraphNode] = []
        var trees: [GraphTree] = []
        var runEdges: [GraphEdge] = []

        for (index, run) in runs.enumerated() {
            let root = roots[index]
            var bottom = root.y + root.height

            for (column, job) in run.jobs.enumerated() {
                let node = GraphNode(
                    id: job.id,
                    kind: .worker,
                    depth: root.depth + 1,
                    index: column,
                    x: lefts[index] + Double(column) * (nodeWidth + siblingGap),
                    y: workerTop,
                    width: nodeWidth,
                    height: height(job.id)
                )
                workers.append(node)
                bottom = max(bottom, node.y + node.height)
                let lane = RunLane(job.status)
                let start = BoardPoint(x: root.centerX, y: root.y + root.height)
                let end = BoardPoint(x: node.centerX, y: node.y)
                let label = connectorLabelPoint(from: start, to: end)
                runEdges.append(GraphEdge(
                    id: "\(root.id)->\(node.id)",
                    from: root.id,
                    to: node.id,
                    lane: lane,
                    start: start,
                    end: end,
                    note: job.routing.flatMap { GraphEdgeNote(routing: $0, at: label) }
                ))

                if mediaByJobID[job.id] != nil {
                    let mediaID = mediaNodeID(job.id)
                    let card = GraphNode(
                        id: mediaID,
                        kind: .media,
                        depth: node.depth + 1,
                        index: column,
                        x: node.x,
                        y: node.y + node.height + levelGap,
                        width: nodeWidth,
                        height: height(mediaID)
                    )
                    media.append(card)
                    bottom = max(bottom, card.y + card.height)
                    runEdges.append(GraphEdge(
                        id: "\(node.id)->\(card.id)",
                        from: node.id,
                        to: card.id,
                        lane: lane,
                        start: BoardPoint(x: node.centerX, y: node.y + node.height),
                        end: BoardPoint(x: card.centerX, y: card.y),
                        note: nil
                    ))
                }
            }

            trees.append(GraphTree(
                id: run.id,
                label: run.label,
                lane: run.state,
                x: lefts[index],
                y: root.y,
                width: spans[index],
                height: bottom - root.y
            ))
        }

        var planner: GraphNode?
        var plannerEdges: [GraphEdge] = []
        if let plannerID, let first = roots.first, let last = roots.last {
            let node = GraphNode(
                id: plannerNodeID(plannerID),
                kind: .planner,
                depth: 0,
                index: 0,
                x: jsRound((first.centerX + last.centerX) / 2 - nodeWidth / 2),
                y: canvasPadding,
                width: nodeWidth,
                height: plannerHeight
            )
            planner = node
            for (index, root) in roots.enumerated() {
                plannerEdges.append(GraphEdge(
                    id: "\(node.id)->\(root.id)",
                    from: node.id,
                    to: root.id,
                    lane: runs[index].state,
                    start: BoardPoint(x: node.centerX, y: node.y + node.height),
                    end: BoardPoint(x: root.centerX, y: root.y),
                    note: nil
                ))
            }
        }

        return BoardGraph(
            planner: planner,
            trees: trees,
            roots: roots,
            workers: workers,
            media: media,
            edges: plannerEdges + runEdges,
            width: cursor - treeGap + canvasPadding,
            height: (trees.map { $0.y + $0.height }.max() ?? 0) + canvasPadding
        )
    }

    /// The midpoint of a connector's horizontal run: the only stretch with room for a label.
    public static func connectorLabelPoint(from start: BoardPoint, to end: BoardPoint) -> BoardPoint {
        BoardPoint(x: (start.x + end.x) / 2, y: start.y + (end.y - start.y) / 2)
    }

    /// A downward elbow with rounded corners: out of the parent's bottom, into the child's top.
    public static func connectorSteps(from start: BoardPoint, to end: BoardPoint) -> [ConnectorStep] {
        let dx = end.x - start.x
        if abs(dx) < 1 { return [.move(start), .vertical(end.y)] }
        let midY = start.y + (end.y - start.y) / 2
        let radius = min(elbowRadius, abs(dx) / 2, abs(end.y - start.y) / 2)
        let step = dx > 0 ? radius : -radius
        return [
            .move(start),
            .vertical(midY - radius),
            .quad(control: BoardPoint(x: start.x, y: midY), to: BoardPoint(x: start.x + step, y: midY)),
            .horizontal(end.x - step),
            .quad(control: BoardPoint(x: end.x, y: midY), to: BoardPoint(x: end.x, y: midY + radius)),
            .vertical(end.y),
        ]
    }

    /// The connector as SVG path data, as upstream draws it.
    public static func connectorPath(from start: BoardPoint, to end: BoardPoint) -> String {
        connectorSteps(from: start, to: end).map(\.svg).joined(separator: " ")
    }

    public static func clampScale(_ scale: Double) -> Double {
        min(maxScale, max(minScale, scale))
    }

    /// The whole graph in the viewport, centred, never enlarged past 1:1.
    public static func fitView(_ graph: BoardSize, in viewport: BoardSize) -> ViewTransform {
        guard graph.width > 0, graph.height > 0, viewport.width > 0, viewport.height > 0 else { return .identity }
        let scale = clampScale(min(1, viewport.width / graph.width, viewport.height / graph.height))
        return ViewTransform(
            scale: scale,
            x: jsRound((viewport.width - graph.width * scale) / 2),
            y: jsRound((viewport.height - graph.height * scale) / 2)
        )
    }

    /// Keeps the canvas point under `point` (viewport coordinates) fixed while scaling.
    public static func zoom(_ view: ViewTransform, by factor: Double, at point: BoardPoint) -> ViewTransform {
        let scale = clampScale(view.scale * factor)
        if scale == view.scale { return view }
        let ratio = scale / view.scale
        return ViewTransform(
            scale: scale,
            x: jsRound(point.x - (point.x - view.x) * ratio),
            y: jsRound(point.y - (point.y - view.y) * ratio)
        )
    }

    /// Centres any box on the board (a node or a whole run tree) without changing the scale.
    public static func focusView(_ box: BoardBox, view: ViewTransform, in viewport: BoardSize) -> ViewTransform {
        ViewTransform(
            scale: view.scale,
            x: jsRound(viewport.width / 2 - (box.x + box.width / 2) * view.scale),
            y: jsRound(viewport.height / 2 - (box.y + box.height / 2) * view.scale)
        )
    }
}

public struct BoardPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct BoardSize: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct BoardBox: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Canvas → viewport: `viewport = canvas * scale + (x, y)`.
public struct ViewTransform: Hashable, Sendable {
    public var scale: Double
    public var x: Double
    public var y: Double

    public static let identity = ViewTransform(scale: 1, x: 0, y: 0)

    public init(scale: Double, x: Double, y: Double) {
        self.scale = scale
        self.x = x
        self.y = y
    }
}

/// One drawing command of a connector, in SVG's absolute terms.
public enum ConnectorStep: Hashable, Sendable {
    case move(BoardPoint)
    case vertical(Double)
    case horizontal(Double)
    case quad(control: BoardPoint, to: BoardPoint)

    public var svg: String {
        switch self {
        case .move(let point): "M\(jsNumber(point.x)) \(jsNumber(point.y))"
        case .vertical(let y): "V\(jsNumber(y))"
        case .horizontal(let x): "H\(jsNumber(x))"
        case .quad(let control, let to):
            "Q\(jsNumber(control.x)) \(jsNumber(control.y)) \(jsNumber(to.x)) \(jsNumber(to.y))"
        }
    }
}

public struct GraphNode: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case planner
        case run
        case worker
        case media
    }

    public var id: String
    public var kind: Kind
    public var depth: Int
    public var index: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(id: String, kind: Kind, depth: Int, index: Int, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.kind = kind
        self.depth = depth
        self.index = index
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var box: BoardBox { BoardBox(x: x, y: y, width: width, height: height) }
}

/// What routing decided when one agent was running out as this worker was spawned, placed on its
/// connector (upstream `GraphEdgeNote`).
public struct GraphEdgeNote: Hashable, Sendable {
    /// `chosen` (the worker went to the other agent) or `ignored` (the planner insisted).
    public var verdict: String
    public var agent: String
    public var window: String
    /// How much of the window was used, in percent.
    public var used: Double
    public var x: Double
    public var y: Double

    public init(verdict: String, agent: String, window: String, used: Double, x: Double, y: Double) {
        self.verdict = verdict
        self.agent = agent
        self.window = window
        self.used = used
        self.x = x
        self.y = y
    }

    /// A job's `routing` object at the connector's label point; nil when it is not an object.
    init?(routing: OrderedJSON, at point: BoardPoint) {
        guard let object = routing.objectValue else { return nil }
        self.init(
            verdict: object["verdict"]?.stringValue ?? "",
            agent: object["agent"]?.stringValue ?? "",
            window: object["window"]?.stringValue ?? "",
            used: object["used"]?.doubleValue ?? 0,
            x: point.x,
            y: point.y
        )
    }
}

public struct GraphEdge: Hashable, Sendable, Identifiable {
    public var id: String
    public var from: String
    public var to: String
    public var lane: RunLane
    public var start: BoardPoint
    public var end: BoardPoint
    /// Only when one agent was running out as this worker was spawned.
    public var note: GraphEdgeNote?

    public init(id: String, from: String, to: String, lane: RunLane, start: BoardPoint, end: BoardPoint, note: GraphEdgeNote?) {
        self.id = id
        self.from = from
        self.to = to
        self.lane = lane
        self.start = start
        self.end = end
        self.note = note
    }

    public var steps: [ConnectorStep] { BoardLayout.connectorSteps(from: start, to: end) }
    /// Upstream's `d`.
    public var path: String { BoardLayout.connectorPath(from: start, to: end) }
}

/// The extent one run's tree occupies. Nothing is drawn around it: it keeps the trees apart and
/// gives the rail a box to bring into view.
public struct GraphTree: Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var lane: RunLane
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(id: String, label: String, lane: RunLane, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.label = label
        self.lane = lane
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var box: BoardBox { BoardBox(x: x, y: y, width: width, height: height) }
}

/// A forest laid out top-down (upstream `BoardGraph`).
public struct BoardGraph: Hashable, Sendable {
    public var planner: GraphNode?
    public var trees: [GraphTree]
    public var roots: [GraphNode]
    public var workers: [GraphNode]
    public var media: [GraphNode]
    public var edges: [GraphEdge]
    public var width: Double
    public var height: Double

    public static let empty = BoardGraph(planner: nil, trees: [], roots: [], workers: [], media: [], edges: [], width: 0, height: 0)

    public init(
        planner: GraphNode?,
        trees: [GraphTree],
        roots: [GraphNode],
        workers: [GraphNode],
        media: [GraphNode],
        edges: [GraphEdge],
        width: Double,
        height: Double
    ) {
        self.planner = planner
        self.trees = trees
        self.roots = roots
        self.workers = workers
        self.media = media
        self.edges = edges
        self.width = width
        self.height = height
    }

    public var size: BoardSize { BoardSize(width: width, height: height) }

    /// Every node, planner first, for hit-testing and focusing by id.
    public var nodes: [GraphNode] { (planner.map { [$0] } ?? []) + roots + workers + media }
}
