import Foundation
import Testing
import XCTest
@testable import AletheIntegrations

/// A ring of `count` nodes in `communities` groups plus chords, like a code graph's mix of chains and
/// hubs; ids are strings, as Graphify writes file paths.
private func syntheticGraph(count: Int, communities: Int = 12) -> GraphData {
    let nodes = (0..<count).map { GraphNode(id: "src/file\($0).ts", label: "file\($0).ts", group: String($0 % communities)) }
    var edges: [GraphEdge] = []
    for index in 0..<count {
        edges.append(GraphEdge(id: "r\(index)", source: nodes[index].id, target: nodes[(index + 1) % count].id))
        if index % 3 == 0 {
            edges.append(GraphEdge(id: "c\(index)", source: nodes[index].id, target: nodes[(index * 7 + 11) % count].id))
        }
    }
    return GraphData(nodes: nodes, edges: edges, nodeCount: count, edgeCount: edges.count, truncated: false)
}

private let upstreamGraph = #"""
{
  "nodes": [
    { "id": "a", "label": "File A", "type": "file" },
    { "id": "b", "name": "func_b", "kind": "function" },
    { "id": "c" }
  ],
  "links": [
    { "source": "a", "target": "b", "relation": "calls" },
    { "source": "b", "target": "c" }
  ]
}
"""#

@Suite struct GraphLayoutTests {
    @Test func theSameSeedGivesTheSameLayout() throws {
        let graph = syntheticGraph(count: 300)
        let first = try ForceLayout.compute(graph, options: .init(seed: 42, iterations: 80))
        let second = try ForceLayout.compute(graph, options: .init(seed: 42, iterations: 80))
        #expect(first == second)
        let other = try ForceLayout.compute(graph, options: .init(seed: 7, iterations: 80))
        #expect(other.positions != first.positions)
    }

    @Test func upstreamsGraphLaysOutWithEdgesByIndex() throws {
        let graph = try GraphData.parse(Data(upstreamGraph.utf8))
        let layout = try ForceLayout.compute(graph)
        #expect(layout.positions.count == 3)
        #expect(layout.edges.map { [$0.source, $0.target] } == [[0, 1], [1, 2]])
        #expect(layout.degrees == [1, 2, 1])
        #expect(layout.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test func linkedNodesEndCloserThanUnlinkedOnes() throws {
        // Two separate pairs: each pair's nodes pull together while the pairs push apart.
        let nodes = ["a", "b", "x", "y"].map { GraphNode(id: $0, label: $0) }
        let edges = [GraphEdge(id: "1", source: "a", target: "b"), GraphEdge(id: "2", source: "x", target: "y")]
        let layout = try ForceLayout.compute(GraphData(nodes: nodes, edges: edges, nodeCount: 4, edgeCount: 2, truncated: false))
        func distance(_ i: Int, _ j: Int) -> Double {
            let dx = layout.positions[i].x - layout.positions[j].x, dy = layout.positions[i].y - layout.positions[j].y
            return (dx * dx + dy * dy).squareRoot()
        }
        #expect(distance(0, 1) < distance(0, 2))
        #expect(distance(2, 3) < distance(1, 3))
    }

    @Test func emptyAndSingleNodeGraphs() throws {
        let empty = try ForceLayout.compute(GraphData(nodes: [], edges: [], nodeCount: 0, edgeCount: 0, truncated: false))
        #expect(empty.positions.isEmpty && empty.bounds.width == 0)
        let single = try ForceLayout.compute(GraphData(nodes: [GraphNode(id: "a", label: "a")], edges: [],
                                                       nodeCount: 1, edgeCount: 0, truncated: false))
        #expect(single.positions.count == 1)
    }

    @Test func aCancelledTaskStopsTheLayout() async {
        let graph = syntheticGraph(count: 2000)
        let task = Task.detached { try ForceLayout.compute(graph, options: .init(iterations: 100_000)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func findsTheNodeNearAPoint() throws {
        let layout = GraphLayout(positions: [GraphPoint(x: 0, y: 0), GraphPoint(x: 10, y: 0)], edges: [], degrees: [0, 0])
        #expect(layout.node(near: GraphPoint(x: 9, y: 1), radius: 3) == 1)
        #expect(layout.node(near: GraphPoint(x: 5, y: 20), radius: 3) == nil)
        #expect(layout.bounds == GraphRect(minX: 0, minY: 0, maxX: 10, maxY: 0))
    }

    @Test func communitiesGetOrdinalsInOrderOfAppearance() {
        let nodes = [GraphNode(id: "a", label: "a", group: "7"), GraphNode(id: "b", label: "b"),
                     GraphNode(id: "c", label: "c", group: "2"), GraphNode(id: "d", label: "d", group: "7")]
        let graph = GraphData(nodes: nodes, edges: [], nodeCount: 4, edgeCount: 0, truncated: false)
        #expect(graph.communityOrdinals == [0, nil, 1, 0])
    }

    @Test func searchMatchesLabelIDAndFilePrefixesFirst() {
        let nodes = [GraphNode(id: "src/router.ts", label: "router.ts", sourceFile: "src/router.ts"),
                     GraphNode(id: "n2", label: "AppRouter"),
                     GraphNode(id: "n3", label: "main", sourceFile: "src/Router/index.ts"),
                     GraphNode(id: "n4", label: "Café")]
        let graph = GraphData(nodes: nodes, edges: [], nodeCount: 4, edgeCount: 0, truncated: false)
        #expect(graph.search("ROUTER") == [0, 1, 2])
        #expect(graph.search("cafe") == [3])
        #expect(graph.search("   ").isEmpty)
        #expect(graph.search("router", limit: 1) == [0])
    }
}

/// P: laying out a graph at upstream's visualization cap (`MAX_VIZ_NODES`, 3000 nodes), the largest
/// graph the view receives; upstream's own fixtures have three nodes.
final class GraphLayoutPerformanceTests: XCTestCase {
    func testLayoutOfTheLargestGraph() throws {
        let graph = syntheticGraph(count: GraphData.visualizationLimit)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            let layout = try? ForceLayout.compute(graph)
            XCTAssertEqual(layout?.positions.count, GraphData.visualizationLimit)
        }
    }
}
