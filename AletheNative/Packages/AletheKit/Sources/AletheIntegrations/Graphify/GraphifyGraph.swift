import Foundation

/// A node of a Graphify graph, normalized from the field names Graphify versions use.
public struct GraphNode: Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var kind: String?
    public var group: String?
    /// The file the node comes from, when the graph records it (P5-23 opens it in a pane).
    public var sourceFile: String?

    public init(id: String, label: String, kind: String? = nil, group: String? = nil, sourceFile: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.group = group
        self.sourceFile = sourceFile
    }
}

public struct GraphEdge: Hashable, Sendable, Identifiable {
    public var id: String
    public var source: String
    public var target: String
    public var label: String?

    public init(id: String, source: String, target: String, label: String? = nil) {
        self.id = id
        self.source = source
        self.target = target
        self.label = label
    }

    /// How the diff identifies an edge (upstream `id_sets`): its endpoints, not its id.
    public var diffKey: String { GraphIDSets.edgeKey(source, target) }
}

/// `graphify-out/graph.json` ready to lay out (upstream `GraphData`). Past `limit` nodes the rest is
/// dropped with the edges touching it; the counts stay the file's totals.
public struct GraphData: Hashable, Sendable {
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]
    public var nodeCount: Int
    public var edgeCount: Int
    public var truncated: Bool

    public init(nodes: [GraphNode], edges: [GraphEdge], nodeCount: Int, edgeCount: Int, truncated: Bool) {
        self.nodes = nodes
        self.edges = edges
        self.nodeCount = nodeCount
        self.edgeCount = edgeCount
        self.truncated = truncated
    }

    /// Upstream `MAX_VIZ_NODES`.
    public static let visualizationLimit = 3000

    /// Upstream `graphify_read_graph`: nodes need an id (string or number); edges read `edges` or
    /// NetworkX's `links` and keep only those between kept nodes.
    public static func parse(_ data: Data, limit: Int = visualizationLimit) throws -> GraphData {
        let root = try GraphJSON.object(data)
        let nodeValues = root["nodes"] as? [Any] ?? []
        let edgeValues = GraphJSON.edges(in: root)

        var nodes: [GraphNode] = []
        var kept = Set<String>()
        for case let object as [String: Any] in nodeValues.prefix(max(limit, 0)) {
            guard let id = GraphJSON.id(object["id"]) else { continue }
            kept.insert(id)
            nodes.append(GraphNode(
                id: id,
                label: GraphJSON.firstString(object, ["label", "name", "title"]) ?? id,
                kind: GraphJSON.firstString(object, ["type", "kind", "category"]),
                group: GraphJSON.firstString(object, ["group", "community", "module"], numbers: true),
                sourceFile: GraphJSON.firstString(object, ["source_file", "sourceFile", "file", "path"])
            ))
        }

        var edges: [GraphEdge] = []
        for case let object as [String: Any] in edgeValues {
            guard let source = GraphJSON.id(object["source"]), let target = GraphJSON.id(object["target"]),
                  kept.contains(source), kept.contains(target) else { continue }
            edges.append(GraphEdge(
                id: GraphJSON.id(object["id"]) ?? GraphIDSets.edgeKey(source, target),
                source: source,
                target: target,
                label: GraphJSON.firstString(object, ["label", "relation", "type"])
            ))
        }
        return GraphData(nodes: nodes, edges: edges, nodeCount: nodeValues.count, edgeCount: edgeValues.count,
                         truncated: nodeValues.count > limit)
    }
}

/// The node ids and edge keys of a graph file, for diffs (upstream `id_sets`; nothing truncated).
public struct GraphIDSets: Hashable, Sendable {
    public var nodes: Set<String>
    public var edges: Set<String>

    public init(nodes: Set<String> = [], edges: Set<String> = []) {
        self.nodes = nodes
        self.edges = edges
    }

    public static func edgeKey(_ source: String, _ target: String) -> String { "\(source)->\(target)" }

    public static func parse(_ data: Data) throws -> GraphIDSets {
        let root = try GraphJSON.object(data)
        var sets = GraphIDSets()
        for case let object as [String: Any] in root["nodes"] as? [Any] ?? [] {
            if let id = GraphJSON.id(object["id"]) { sets.nodes.insert(id) }
        }
        for case let object as [String: Any] in GraphJSON.edges(in: root) {
            if let source = GraphJSON.id(object["source"]), let target = GraphJSON.id(object["target"]) {
                sets.edges.insert(edgeKey(source, target))
            }
        }
        return sets
    }
}

/// What changed from a base graph to a compared one (upstream `GraphDiff`), with the ids so the view
/// can highlight them.
public struct GraphDiff: Hashable, Sendable {
    public var addedNodes: Set<String>
    public var removedNodes: Set<String>
    public var addedEdges: Set<String>
    public var removedEdges: Set<String>

    public init(base: GraphIDSets, compare: GraphIDSets) {
        addedNodes = compare.nodes.subtracting(base.nodes)
        removedNodes = base.nodes.subtracting(compare.nodes)
        addedEdges = compare.edges.subtracting(base.edges)
        removedEdges = base.edges.subtracting(compare.edges)
    }

    public var nodesAdded: Int { addedNodes.count }
    public var nodesRemoved: Int { removedNodes.count }
    public var edgesAdded: Int { addedEdges.count }
    public var edgesRemoved: Int { removedEdges.count }
    public var isEmpty: Bool { addedNodes.isEmpty && removedNodes.isEmpty && addedEdges.isEmpty && removedEdges.isEmpty }
}

public enum GraphifyError: Error, Equatable, Sendable {
    /// No `graphify-out/graph.json` (upstream `graph_not_found`).
    case graphNotFound
    /// The file is not a JSON object (upstream `invalid_graph_json`).
    case invalidGraph
    /// Not a numeric snapshot id: never turned into a path (upstream `invalid_snapshot_id`).
    case invalidSnapshotID
    case snapshotNotFound
}

private enum GraphJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GraphifyError.invalidGraph
        }
        return object
    }

    static func edges(in root: [String: Any]) -> [Any] {
        (root["edges"] as? [Any]) ?? (root["links"] as? [Any]) ?? []
    }

    /// Strings and numbers are ids (upstream `value_to_id`); booleans are not.
    static func id(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return number.stringValue
        default: return nil
        }
    }

    /// Upstream `first_str`: the first key holding a string. With `numbers`, a number counts too:
    /// Graphify writes `community` as one, and upstream then lost the grouping.
    static func firstString(_ object: [String: Any], _ keys: [String], numbers: Bool = false) -> String? {
        for key in keys {
            if let string = object[key] as? String { return string }
            if numbers, let id = id(object[key]) { return id }
        }
        return nil
    }
}
