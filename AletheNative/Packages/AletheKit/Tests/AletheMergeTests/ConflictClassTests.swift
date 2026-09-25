import Testing
@testable import AletheMerge

/// Golden cases ported from upstream `merge_analyzer.rs` (`classifies_by_extension_and_special_paths`).
struct ConflictClassTests {
    @Test(arguments: [
        ("src-tauri/src/pty.rs", ConflictClass.rust),
        ("src/lib/tauri.ts", .typeScript),
        ("src/App.module.css", .ui),
        ("src-tauri/Cargo.lock", .cargo),
        ("package-lock.json", .package),
        ("tauri.conf.json", .json),
        ("config/settings.yml", .config),
        ("assets/logo.png", .asset),
        (".planning/roadmap.md", .planning),
        ("graphify-out/graph.json", .graph),
        ("README.md", .other),
        ("src\\main.rs", .rust),
    ])
    func upstreamGolden(path: String, expected: ConflictClass) {
        #expect(ConflictClass.classify(path) == expected)
    }

    @Test func sentinelsBeatPlanning() {
        #expect(ConflictClass.classify(".planning/.gsd-child-session") == .sentinel)
        #expect(ConflictClass.classify("x/.GSD-CHILD-BUSY") == .sentinel)
        #expect(ConflictClass.classify("app/.planning/notes.md") == .planning)
        #expect(ConflictClass.classify("pkg/graphify-out/x.rs") == .graph)
    }

    @Test func manifestsAndExtensions() {
        #expect(ConflictClass.classify("Cargo.toml") == .cargo)
        #expect(ConflictClass.classify("web/pnpm-lock.yaml") == .package)
        #expect(ConflictClass.classify("yarn.lock") == .package)
        #expect(ConflictClass.classify("a.MTS") == .typeScript)
        #expect(ConflictClass.classify("font.woff2") == .asset)
        #expect(ConflictClass.classify("Makefile") == .other)
        #expect(ConflictClass.classify("other.toml") == .config)
    }

    @Test func everyClassHasAStrategy() {
        for c in ConflictClass.allCases { #expect(!c.strategy.isEmpty) }
        #expect(ConflictClass.sentinel.strategy.contains("deleting the file"))
    }

    @Test func classesAreDistinctAndSortedByVariantName() {
        let analysis = MergeAnalysis(clean: false, source: "a", target: "b", conflicts: [
            ConflictFile(path: "x.ts"), ConflictFile(path: "y.rs"), ConflictFile(path: "z.ts"),
            ConflictFile(path: "logo.png"), ConflictFile(path: "ui.css"),
        ])
        #expect(analysis.classes == [.asset, .rust, .typeScript, .ui])
    }

    @Test func stages() {
        #expect(MergeCenterStage.allCases == [.analyze, .prepare, .validate, .finish])
        #expect(MergeCenterStage.analyze.next == .prepare)
        #expect(MergeCenterStage.finish.next == nil)
        #expect(MergeCenterStage.after(MergeAnalysis(clean: true, source: "a", target: "b", conflicts: [])) == .validate)
        #expect(MergeCenterStage.after(MergeAnalysis(clean: false, source: "a", target: "b",
                                                     conflicts: [ConflictFile(path: "a.rs")])) == .prepare)
    }
}
