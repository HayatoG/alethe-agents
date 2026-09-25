import Foundation
import Testing
@testable import AletheIntegrations

/// Upstream `graphify.rs` tests' graph (`temp_repo_with_graph`): mixed field names, `links`.
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

/// Upstream's smaller graph after an edit: `c` and the edge to it are gone.
private let upstreamSmallerGraph = #"{ "nodes": [ { "id": "a" }, { "id": "b" } ], "links": [ { "source": "a", "target": "b" } ]}"#

/// The shape Graphify writes (NetworkX node-link data): numeric communities, source files, `edges`.
private let nodeLinkGraph = #"""
{
  "directed": false,
  "graph": {},
  "nodes": [
    { "id": "src/app.ts", "label": "app.ts", "file_type": "code", "source_file": "src/app.ts", "community": 0 },
    { "id": 7, "title": "Seven", "category": "concept", "group": "core" },
    { "id": true, "label": "not an id" },
    { "label": "no id" }
  ],
  "edges": [
    { "id": "e1", "source": "src/app.ts", "target": 7, "type": "imports" },
    { "source": 7, "target": "missing" },
    { "source": "src/app.ts" }
  ]
}
"""#

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "AletheGraphifyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A repository with `graphify-out/graph.json` holding `graph`.
private func repositoryWithGraph(_ graph: String = upstreamGraph) throws -> URL {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
    try write(graph, to: GraphifyRepository(root: root).graphURL)
    return root
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// A clock that advances `step` seconds per call.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private let step: TimeInterval

    init(start: Date = Date(timeIntervalSince1970: 1_750_000_000), step: TimeInterval = 1) {
        current = start
        self.step = step
    }

    func next() -> Date {
        lock.withLock {
            defer { current = current.addingTimeInterval(step) }
            return current
        }
    }
}

/// A stand-in `graphify`: prints a version, writes a one-node graph, or hangs, as asked.
private func fakeCLI(in folder: URL, generation: String) throws -> String {
    let url = folder.appending(path: "graphify")
    try write("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "graphify 0.4.1"; exit 0; fi
    \(generation)
    """, to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

private let writesGraph = #"mkdir -p "$1/graphify-out" && echo '{"nodes":[{"id":"a"}],"links":[]}' > "$1/graphify-out/graph.json""#

@Suite struct GraphifyGraphTests {
    @Test func readsAndNormalizesUpstreamsGraph() throws {
        let data = try GraphData.parse(Data(upstreamGraph.utf8))
        #expect(data.nodeCount == 3 && data.nodes.count == 3)
        #expect(data.edgeCount == 2 && data.edges.count == 2)
        #expect(!data.truncated)
        let byID = Dictionary(uniqueKeysWithValues: data.nodes.map { ($0.id, $0) })
        #expect(byID["a"] == GraphNode(id: "a", label: "File A", kind: "file"))
        #expect(byID["b"] == GraphNode(id: "b", label: "func_b", kind: "function"))
        #expect(byID["c"]?.label == "c", "the id stands in for a missing label")
        #expect(data.edges[0] == GraphEdge(id: "a->b", source: "a", target: "b", label: "calls"))
        #expect(data.edges[1].label == nil)
    }

    @Test func readsGraphifysNodeLinkShape() throws {
        let data = try GraphData.parse(Data(nodeLinkGraph.utf8))
        #expect(data.nodes.map(\.id) == ["src/app.ts", "7"], "booleans and missing ids are skipped")
        #expect(data.nodeCount == 4 && data.edgeCount == 3)
        let app = data.nodes[0]
        #expect(app.sourceFile == "src/app.ts" && app.group == "0" && app.label == "app.ts")
        #expect(data.nodes[1] == GraphNode(id: "7", label: "Seven", kind: "concept", group: "core"))
        #expect(data.edges == [GraphEdge(id: "e1", source: "src/app.ts", target: "7", label: "imports")],
                "edges to unknown nodes and without a target are dropped")
    }

    @Test func truncatesPastTheLimitKeepingTotals() throws {
        let nodes = (0..<10).map { #"{ "id": "n\#($0)" }"# }.joined(separator: ",")
        let edges = (0..<9).map { #"{ "source": "n\#($0)", "target": "n\#($0 + 1)" }"# }.joined(separator: ",")
        let data = try GraphData.parse(Data(#"{ "nodes": [\#(nodes)], "edges": [\#(edges)] }"#.utf8), limit: 4)
        #expect(data.truncated)
        #expect(data.nodes.map(\.id) == ["n0", "n1", "n2", "n3"])
        #expect(data.edges.count == 3, "only edges between kept nodes")
        #expect(data.nodeCount == 10 && data.edgeCount == 9)
        #expect(GraphData.visualizationLimit == 3000)
    }

    @Test func refusesWhatIsNotAGraphObject() {
        #expect(throws: GraphifyError.invalidGraph) { try GraphData.parse(Data("[1, 2]".utf8)) }
        #expect(throws: GraphifyError.invalidGraph) { try GraphData.parse(Data("{ nope".utf8)) }
        #expect(throws: GraphifyError.invalidGraph) { try GraphIDSets.parse(Data("".utf8)) }
    }

    @Test func anEmptyObjectIsAnEmptyGraph() throws {
        let data = try GraphData.parse(Data("{}".utf8))
        #expect(data.nodes.isEmpty && data.edges.isEmpty && data.nodeCount == 0 && !data.truncated)
    }

    @Test func diffComparesNodeAndEdgeSets() throws {
        let base = try GraphIDSets.parse(Data(upstreamGraph.utf8))
        let smaller = try GraphIDSets.parse(Data(upstreamSmallerGraph.utf8))
        #expect(base.nodes == ["a", "b", "c"] && base.edges == ["a->b", "b->c"])

        let diff = GraphDiff(base: base, compare: smaller)
        #expect(diff.removedNodes == ["c"] && diff.removedEdges == ["b->c"])
        #expect(diff.nodesAdded == 0 && diff.edgesAdded == 0 && diff.nodesRemoved == 1 && diff.edgesRemoved == 1)

        let back = GraphDiff(base: smaller, compare: base)
        #expect(back.addedNodes == ["c"] && back.addedEdges == ["b->c"] && back.nodesRemoved == 0)
        #expect(GraphDiff(base: base, compare: base).isEmpty)
    }

    @Test func edgesDiffByEndpointsNotByID() throws {
        let one = try GraphIDSets.parse(Data(#"{ "nodes": [], "edges": [ { "id": "x", "source": 1, "target": 2 } ] }"#.utf8))
        let two = try GraphIDSets.parse(Data(#"{ "nodes": [], "links": [ { "id": "y", "source": "1", "target": "2" } ] }"#.utf8))
        #expect(GraphDiff(base: one, compare: two).isEmpty)
        #expect(GraphEdge(id: "y", source: "1", target: "2").diffKey == "1->2")
    }
}

@Suite struct GraphifyRepositoryTests {
    @Test func snapshotListDiffRollbackAndPrune() throws {
        // Upstream `snapshot_list_diff_rollback_and_prune`.
        let root = try repositoryWithGraph()
        let repository = GraphifyRepository(root: root)

        let snapshot = try repository.snapshot()
        #expect(snapshot.sizeBytes > 0)
        #expect(snapshot.url.path.hasSuffix(".alethe/graph-snapshots/\(snapshot.id).json"))
        #expect(repository.snapshots().map(\.id) == [snapshot.id])

        try write(upstreamSmallerGraph, to: repository.graphURL)
        let diff = try repository.diff(base: snapshot.id)
        #expect(diff.nodesRemoved == 1 && diff.edgesRemoved == 1)

        try repository.rollback(to: snapshot.id)
        #expect(try repository.readGraph().nodeCount == 3)

        #expect(repository.prune(keepLast: 0) == 1)
        #expect(repository.snapshots().isEmpty)
    }

    @Test func snapshotsInTheSameMillisecondGetTheirOwnIDs() throws {
        let root = try repositoryWithGraph()
        let fixed = Date(timeIntervalSince1970: 1_750_000_000.123)
        let repository = GraphifyRepository(root: root, now: { fixed })
        let first = try repository.snapshot()
        let second = try repository.snapshot()
        #expect(first.id == "1750000000123" && second.id == "1750000000124")
        #expect(repository.snapshots().map(\.id) == [second.id, first.id], "newest first")
    }

    @Test func diffsTwoSnapshots() throws {
        let root = try repositoryWithGraph(upstreamSmallerGraph)
        let clock = SteppingClock()
        let repository = GraphifyRepository(root: root, now: { clock.next() })
        let before = try repository.snapshot()
        try write(upstreamGraph, to: repository.graphURL)
        let after = try repository.snapshot()
        let diff = try repository.diff(base: before.id, compare: after.id)
        #expect(diff.addedNodes == ["c"] && diff.addedEdges == ["b->c"] && diff.nodesRemoved == 0)
    }

    @Test func listsTheTauriAppsSnapshotsAndIgnoresOtherFiles() throws {
        let root = try repositoryWithGraph()
        let repository = GraphifyRepository(root: root)
        let folder = repository.snapshotsFolder
        try write(upstreamGraph, to: folder.appending(path: "1700000000000.json"))
        try write(upstreamGraph, to: folder.appending(path: "1710000000000.json"))
        try write("{}", to: folder.appending(path: "notes.json"))
        try write("{}", to: folder.appending(path: "1720000000000.txt"))
        try write("{}", to: folder.appending(path: "-5.json"))
        let snapshots = repository.snapshots()
        #expect(snapshots.map(\.id) == ["1710000000000", "1700000000000"])
        #expect(snapshots[0].createdAt == Date(timeIntervalSince1970: 1_710_000_000))
        #expect(snapshots[0].sizeBytes == upstreamGraph.utf8.count)
    }

    @Test func prunesByCountAndByAge() throws {
        let root = try repositoryWithGraph()
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = SteppingClock(start: start, step: day)
        let writer = GraphifyRepository(root: root, now: { clock.next() })
        for _ in 0..<5 { try writer.snapshot() }  // days 0…4

        let later = GraphifyRepository(root: root, now: { start.addingTimeInterval(4 * day) })
        #expect(later.prune(keepLast: 4) == 1, "the oldest past the newest four")
        #expect(later.snapshots().count == 4)
        #expect(later.prune(keepLast: 10, maxAgeDays: 2) == 1, "older than two days (day 1)")
        #expect(later.snapshots().map(\.createdAt) == [4, 3, 2].map { start.addingTimeInterval($0 * day) })
        #expect(later.prune(keepLast: 10) == 0)
    }

    @Test func rejectsForgedSnapshotIDs() throws {
        // Upstream `rejects_forged_snapshot_id`.
        let root = try repositoryWithGraph()
        let repository = GraphifyRepository(root: root)
        #expect(throws: GraphifyError.invalidSnapshotID) { try repository.rollback(to: "../evil") }
        #expect(throws: GraphifyError.invalidSnapshotID) { try repository.diff(base: "abc") }
        #expect(throws: GraphifyError.invalidSnapshotID) { try repository.diff(base: "") }
        #expect(throws: GraphifyError.invalidSnapshotID) { try repository.rollback(to: "１２") }
        #expect(throws: GraphifyError.snapshotNotFound) { try repository.rollback(to: "123") }
    }

    @Test func aMissingGraphIsReported() throws {
        let root = temporaryDirectory()
        let repository = GraphifyRepository(root: root)
        #expect(!repository.hasGraph)
        #expect(throws: GraphifyError.graphNotFound) { try repository.readGraph() }
        #expect(throws: GraphifyError.graphNotFound) { try repository.snapshot() }
        #expect(repository.snapshots().isEmpty)
    }

    @Test func rollbackRecreatesTheOutputFolder() throws {
        let root = try repositoryWithGraph()
        let repository = GraphifyRepository(root: root)
        let snapshot = try repository.snapshot()
        try FileManager.default.removeItem(at: repository.graphURL.deletingLastPathComponent())
        try repository.rollback(to: snapshot.id)
        #expect(repository.hasGraph)
    }

    @Test func findsTheRepositoryRoot() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        let nested = root.appending(path: "src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(GraphifyRepository.repositoryRoot(containing: nested)?.path == root.standardizedFileURL.path)

        // A linked worktree has a `.git` file and is its own root.
        let worktree = root.appending(path: "worktrees/feature")
        try write("gitdir: ../../.git/worktrees/feature\n", to: worktree.appending(path: ".git"))
        #expect(GraphifyRepository.repositoryRoot(containing: worktree)?.path == worktree.standardizedFileURL.path)
    }
}

@Suite struct GraphifyServiceTests {
    @Test func mcpServerArguments() {
        // Upstream `mcp_server_spec`: `<command> <root> --mcp`.
        #expect(GraphifyService.mcpArguments(root: URL(filePath: "/repo/app/")) == ["/repo/app", "--mcp"])
        #expect(GraphifyService.defaultCommand == "graphify")
    }

    @Test func detectsTheCLIAndItsVersion() async throws {
        let cli = try fakeCLI(in: temporaryDirectory(), generation: "exit 0")
        let service = GraphifyService()
        #expect(await service.detect(executable: cli) == GraphifyStatus(available: true, executable: cli, version: "graphify 0.4.1"))
        #expect(await service.detect(executable: "/nonexistent/alethe-graphify") ==
                GraphifyStatus(available: false, executable: "/nonexistent/alethe-graphify"))
        #expect(await service.detect(executable: nil) == GraphifyStatus(available: false, executable: nil))
    }

    @Test func ensureGraphStates() async throws {
        // Upstream `ensure_graph_bootstrap_states`.
        let service = GraphifyService()
        let withGraph = try repositoryWithGraph()
        #expect(await service.ensureGraph(root: withGraph, executable: nil) == .exists)

        let bare = temporaryDirectory()
        #expect(await service.ensureGraph(root: bare, executable: "/nonexistent/alethe-graphify") == .unavailable)
        #expect(await service.ensureGraph(root: bare, executable: nil) == .unavailable)

        let slow = try fakeCLI(in: temporaryDirectory(), generation: "sleep 30")
        #expect(await service.ensureGraph(root: bare, executable: slow) == .started)
        #expect(await service.isGenerating(bare))
        #expect(await service.ensureGraph(root: bare, executable: slow) == .generating, "one run per repository")
        await service.cancelGeneration(root: bare)
    }

    @Test func generatesAndReadsTheGraph() async throws {
        let root = temporaryDirectory()
        let cli = try fakeCLI(in: temporaryDirectory(), generation: writesGraph)
        let service = GraphifyService()
        #expect(await service.generate(root: root, executable: cli) == .generated)
        #expect(await !service.isGenerating(root))
        #expect(try await service.readGraph(root: root).nodes.map(\.id) == ["a"])
        #expect(await service.ensureGraph(root: root, executable: cli) == .exists)
    }

    @Test func ensureGraphReportsTheOutcome() async throws {
        let root = temporaryDirectory()
        let cli = try fakeCLI(in: temporaryDirectory(), generation: writesGraph)
        let service = GraphifyService()
        let outcome = await withCheckedContinuation { continuation in
            Task { _ = await service.ensureGraph(root: root, executable: cli) { continuation.resume(returning: $0) } }
        }
        #expect(outcome == .generated)
    }

    @Test func aFailedGenerationCarriesStderr() async throws {
        let cli = try fakeCLI(in: temporaryDirectory(), generation: "echo 'no files to index' >&2; exit 3")
        let outcome = await GraphifyService().generate(root: temporaryDirectory(), executable: cli)
        #expect(outcome == .failed("no files to index"))
    }

    @Test func generationIsCancelable() async throws {
        let root = temporaryDirectory()
        let cli = try fakeCLI(in: temporaryDirectory(), generation: "sleep 30")
        let service = GraphifyService()
        let run = Task { await service.generate(root: root, executable: cli) }
        try await Task.sleep(for: .milliseconds(300))
        await service.cancelGeneration(root: root)
        #expect(await run.value == .cancelled)
        #expect(await !service.isGenerating(root))
    }

    @Test func generationTimesOut() async throws {
        let cli = try fakeCLI(in: temporaryDirectory(), generation: "sleep 30")
        let service = GraphifyService(generationTimeout: .milliseconds(300))
        #expect(await service.generate(root: temporaryDirectory(), executable: cli) == .timedOut)
    }

    @Test func snapshotsThroughTheService() async throws {
        let root = try repositoryWithGraph()
        let service = GraphifyService()
        let snapshot = try await service.snapshot(root: root)
        #expect(await service.snapshots(root: root).map(\.id) == [snapshot.id])
        #expect(try await service.diff(root: root, base: snapshot.id).isEmpty)
        try await service.rollback(root: root, to: snapshot.id)
        #expect(await service.prune(root: root, keepLast: 0) == 1)
    }
}

@Suite struct ExternalCommandTests {
    @Test func capturesOutputAndExitCode() async throws {
        let result = try await ExternalCommand.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 4"], timeout: .seconds(10))
        #expect(result == ExternalCommandResult(exitCode: 4, stdout: "out\n", stderr: "err\n"))
        #expect(!result.succeeded)
    }

    @Test func runsInTheGivenDirectory() async throws {
        let folder = temporaryDirectory()
        let result = try await ExternalCommand.run("/bin/pwd", [], directory: folder, timeout: .seconds(10))
        #expect(URL(filePath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
                == folder.resolvingSymlinksInPath().path)
    }

    @Test func timesOut() async {
        await #expect(throws: ExternalCommandError.timedOut) {
            try await ExternalCommand.run("/bin/sleep", ["30"], timeout: .milliseconds(200))
        }
    }

    @Test func aMissingExecutableFailsToLaunch() async {
        await #expect {
            try await ExternalCommand.run("/nonexistent/tool", [], timeout: .seconds(5))
        } throws: { error in
            if case ExternalCommandError.launchFailed = error { true } else { false }
        }
    }

    @Test func cancellingStopsTheProcess() async throws {
        let run = Task { try await ExternalCommand.run("/bin/sleep", ["30"], timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(200))
        run.cancel()
        await #expect(throws: ExternalCommandError.cancelled) { try await run.value }
    }
}
