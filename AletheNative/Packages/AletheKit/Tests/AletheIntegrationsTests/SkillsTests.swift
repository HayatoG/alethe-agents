import Foundation
import Testing
@testable import AletheIntegrations

/// A throwaway home with skills laid out like a real one.
private struct Home {
    let url: URL
    let store: SkillStore

    init() {
        url = FileManager.default.temporaryDirectory
            .appending(path: "AletheSkillsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = SkillStore(home: url, useTrash: false)
    }

    @discardableResult
    func skill(_ relative: String, _ text: String = "---\nname: x\ndescription: A skill\n---\n\n# Body\n") -> URL {
        let dir = url.appending(path: relative, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: dir.appending(path: SkillStore.skillFile))
        return dir
    }

    func file(_ relative: String, _ text: String = "x") {
        let file = url.appending(path: relative)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file)
    }

    func link(_ relative: String, to target: URL) {
        let link = url.appending(path: relative)
        try? FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: relative).path)
    }

    func snapshot(_ agent: SkillAgent) throws -> SkillAgentSnapshot {
        try #require(try store.scanNow().first { $0.agent == agent })
    }
}

@Suite struct SkillFrontmatterTests {
    @Test func readsPlainQuotedAndSingleQuotedValues() {
        let fields = SkillFrontmatter.parse("name: motion\ndescription: \"Creates motion graphics\"\nlicense: 'MIT'")
        #expect(fields["name"] == "motion")
        #expect(fields["description"] == "Creates motion graphics")
        #expect(fields["license"] == "MIT")
    }

    @Test func joinsAFoldedBlock() {
        let fields = SkillFrontmatter.parse("name: pptx\ndescription: >-\n  Use this skill any time\n  a .pptx file is involved.\n")
        #expect(fields["description"] == "Use this skill any time a .pptx file is involved.")
    }

    @Test func keepsLiteralBlockLines() {
        let fields = SkillFrontmatter.parse("notes: |\n  first\n\n  second\n")
        #expect(fields["notes"] == "first\nsecond")
    }

    @Test func keepsANestedMapAsItsIndentedText() {
        let fields = SkillFrontmatter.parse("name: imagegen\nmetadata:\n  short-description: Generates images\n")
        #expect(fields["metadata"] == "short-description: Generates images")
    }

    @Test func valuesKeepColonsAndCommentsAndListsAreSkipped() {
        let fields = SkillFrontmatter.parse("# comment\nurl: https://example.com/a\n- stray\nallowed-tools:\n  - Read\n  - Bash\n")
        #expect(fields["url"] == "https://example.com/a")
        #expect(fields["allowed-tools"] == "- Read - Bash")
        #expect(fields.count == 2)
    }

    @Test func splitSeparatesBodyAndToleratesItsAbsence() {
        let parts = SkillFrontmatter.split("---\nname: a\n---\n\n# Title\ntext\n")
        #expect(parts.front == "name: a")
        #expect(parts.body.hasPrefix("# Title"))

        let none = SkillFrontmatter.split("# Just a body\n")
        #expect(none.front.isEmpty)
        #expect(none.body == "# Just a body\n")

        let unclosed = SkillFrontmatter.split("---\nname: a\n")
        #expect(unclosed.front.isEmpty)
        #expect(unclosed.body == "---\nname: a\n")
    }

    @Test func splitHandlesWindowsLineEndingsAndAnEmptyBlock() {
        let crlf = SkillFrontmatter.split("---\r\nname: a\r\n---\r\nbody\r\n")
        #expect(crlf.front == "name: a")
        #expect(crlf.body == "body\n")
        let empty = SkillFrontmatter.split("---\n---\nbody")
        #expect(empty.front.isEmpty)
        #expect(empty.body == "body")
    }
}

@Suite struct SkillNameTests {
    @Test func aCraftedNameCannotEscapeTheRoot() {
        for name in ["../../etc", "a/b", "a\\b", "c:d", "..", ".", "   ", ""] {
            #expect(throws: SkillError.invalidName) { try SkillStore.validate(name: name) }
        }
        #expect(throws: Never.self) { try SkillStore.validate(name: "promo-film") }
    }

    @Test func detailAndUninstallRejectInvalidNamesBeforeTouchingDisk() {
        let home = Home()
        home.skill(".claude/skills/brand")
        #expect(throws: SkillError.invalidName) { try home.store.detailNow(agent: .claude, name: "../skills/brand") }
        #expect(throws: SkillError.invalidName) { try home.store.uninstallNow(agent: .claude, name: "..") }
        #expect(home.exists(".claude/skills/brand/SKILL.md"))
    }

    @Test func aSymlinkedParentOutsideTheRootIsRefused() throws {
        let home = Home()
        let outside = home.skill("elsewhere/evil")
        // `.system` pointing outside the root: the skill's parent is not under the root.
        home.link(".codex/skills/.system", to: outside.deletingLastPathComponent())
        #expect(throws: SkillError.outsideRoot) { try home.store.detailNow(agent: .codex, name: "evil") }
    }
}

@Suite struct SkillScanTests {
    @Test func returnsOneSnapshotPerRootEvenWhenMissing() throws {
        let home = Home()
        let snapshots = try home.store.scanNow()
        #expect(snapshots.map(\.agent) == SkillAgent.allCases)
        #expect(snapshots.allSatisfy { !$0.exists && $0.skills.isEmpty })
        #expect(snapshots.first { $0.agent == .opencode }?.root.hasSuffix(".config/opencode/skill") == true)
    }

    @Test func listsSkillsSortedAndSkipsFoldersWithoutSkillFileAndHiddenOnes() throws {
        let home = Home()
        home.skill(".claude/skills/zeta", "---\ndescription: Last\n---\nbody")
        home.skill(".claude/skills/alpha", "---\ndescription: First\n---\nbody")
        home.file(".claude/skills/empty/notes.md")
        home.skill(".claude/skills/.hidden")
        home.file(".claude/skills/loose.md")
        let claude = try home.snapshot(.claude)
        #expect(claude.exists)
        #expect(claude.skills.map(\.name) == ["alpha", "zeta"])
        #expect(claude.skills.first?.description == "First")
        #expect(claude.skills.first?.entryCount == 1)
    }

    @Test func codexSystemSkillsAreBundled() throws {
        let home = Home()
        home.skill(".codex/skills/.system/imagegen")
        home.skill(".codex/skills/vendor/tool")
        home.file(".codex/skills/vendor/.codex-system-skills.marker")
        home.skill(".codex/skills/mine")
        let codex = try home.snapshot(.codex)
        #expect(codex.skills.map(\.name) == ["imagegen", "mine"])
        #expect(codex.skills.first { $0.name == "imagegen" }?.bundled == true)
        #expect(codex.skills.first { $0.name == "mine" }?.bundled == false)
        // The marker marks every skill beneath its folder.
        #expect(home.store.summarize(.codex, root: home.store.root(for: .codex),
                                     dir: home.url.appending(path: ".codex/skills/vendor/tool"))?.bundled == true)
    }

    @Test func aLinkIntoTheSharedStoreIsResolved() throws {
        let home = Home()
        let shared = home.skill(".agents/skills/brand", "---\ndescription: Brand system\n---\nbody")
        home.link(".claude/skills/brand", to: shared)
        home.link(".config/opencode/skill/brand", to: shared)
        let claude = try #require(try home.snapshot(.claude).skills.first)
        #expect(claude.linked)
        #expect(claude.shared)
        #expect(claude.description == "Brand system")
        #expect(claude.resolvedPath == SkillStore.canonical(shared).path)
        let own = try #require(try home.snapshot(.shared).skills.first)
        #expect(!own.linked)
        #expect(!own.shared, "the shared store's own entry is not 'shared'")
    }

    @Test func eachAgentRootIsScanned() throws {
        let home = Home()
        for agent in SkillAgent.allCases {
            home.skill((agent.segments + ["only-\(agent.rawValue)"]).joined(separator: "/"))
        }
        for snapshot in try home.store.scanNow() {
            #expect(snapshot.skills.map(\.name) == ["only-\(snapshot.agent.rawValue)"])
            #expect(snapshot.skills.allSatisfy { $0.agent == snapshot.agent })
        }
    }

    @Test func asyncScanMatchesAndHonoursCancellation() async throws {
        let home = Home()
        home.skill(".claude/skills/brand")
        let snapshots = try await home.store.scan()
        #expect(snapshots.first { $0.agent == .claude }?.skills.count == 1)

        let task = Task { try await home.store.scan() }
        task.cancel()
        _ = await task.result // either finished before the cancel or threw CancellationError; never hangs
    }
}

@Suite struct SkillDetailTests {
    @Test func readsFrontmatterBodyTreeAndLock() throws {
        let home = Home()
        let dir = home.skill(".claude/skills/motion", "---\nname: motion\ndescription: >\n  Makes\n  motion\n---\n\n# Motion\n")
        home.file(".claude/skills/motion/references/guide.md")
        home.file(".claude/skills/motion/Zeta.txt")
        home.file(".agents/.skill-lock.json", """
        {"version":1,"skills":{"motion":{"source":"owner/repo","sourceUrl":"https://github.com/owner/repo",
        "installedAt":"2026-01-01","updatedAt":"2026-02-02"}}}
        """)
        let detail = try home.store.detailNow(agent: .claude, name: "motion")
        #expect(detail.summary.path == dir.path)
        #expect(detail.frontmatter["description"] == "Makes motion")
        #expect(detail.frontmatterRaw.hasPrefix("name: motion"))
        #expect(detail.body == "# Motion\n")
        #expect(detail.tree.map(\.name) == ["references", "SKILL.md", "Zeta.txt"], "folders first, then by name")
        #expect(detail.tree.first?.children.map(\.name) == ["guide.md"])
        #expect(detail.lock?.source == "owner/repo")
        #expect(detail.lock?.sourceURL == "https://github.com/owner/repo")
        #expect(detail.lock?.updatedAt == "2026-02-02")
    }

    @Test func aSystemSkillIsFoundAndAMissingOneIsNot() throws {
        let home = Home()
        home.skill(".codex/skills/.system/imagegen")
        #expect(try home.store.detailNow(agent: .codex, name: "imagegen").summary.bundled)
        #expect(throws: SkillError.notFound) { try home.store.detailNow(agent: .codex, name: "nope") }
        #expect(try home.store.detailNow(agent: .codex, name: "imagegen").lock == nil)
    }

    @Test func theTreeIsCappedInDepthAndWidth() throws {
        let home = Home()
        home.skill(".claude/skills/deep")
        home.file(".claude/skills/deep/a/b/c/d/e/file.txt")
        for index in 0..<(SkillStore.maxTreeChildren + 5) { home.file(".claude/skills/deep/many/\(index).txt") }
        let tree = try home.store.detailNow(agent: .claude, name: "deep").tree
        let a = try #require(tree.first { $0.name == "a" })
        let d = try #require(a.children.first?.children.first?.children.first)
        #expect(d.name == "d")
        #expect(d.children.isEmpty, "depth 4 stops listing")
        let many = try #require(tree.first { $0.name == "many" })
        #expect(many.children.count == SkillStore.maxTreeChildren)
        let allTruncated = many.children.allSatisfy(\.truncated)
        #expect(allTruncated)
    }
}

@Suite struct SkillUninstallTests {
    @Test func removesAPlainSkillFolder() throws {
        let home = Home()
        home.skill(".claude/skills/brand")
        let report = try home.store.uninstallNow(agent: .claude, name: "brand")
        #expect(!report.removedLinkOnly)
        #expect(!report.movedToTrash)
        #expect(!home.exists(".claude/skills/brand"))
    }

    @Test func removesOnlyTheLinkAndKeepsTheSharedCopy() throws {
        let home = Home()
        let shared = home.skill(".agents/skills/brand")
        home.link(".claude/skills/brand", to: shared)
        let report = try home.store.uninstallNow(agent: .claude, name: "brand")
        #expect(report.removedLinkOnly)
        #expect(report.sharedCopyPath == SkillStore.canonical(shared).path)
        #expect(!home.exists(".claude/skills/brand"))
        #expect(home.exists(".agents/skills/brand/SKILL.md"))
    }

    @Test func refusesABundledSkill() {
        let home = Home()
        home.skill(".codex/skills/.system/imagegen")
        #expect(throws: SkillError.bundled) { try home.store.uninstallNow(agent: .codex, name: "imagegen") }
        #expect(home.exists(".codex/skills/.system/imagegen/SKILL.md"))
    }
}

@Suite struct SkillGroupTests {
    private func skill(_ agent: SkillAgent, _ name: String, description: String = "", linked: Bool = false,
                       bundled: Bool = false) -> SkillSummary {
        SkillSummary(name: name, agent: agent, path: "/\(agent.rawValue)/\(name)", resolvedPath: "/\(agent.rawValue)/\(name)",
                     description: description, linked: linked, bundled: bundled)
    }

    private func snapshot(_ agent: SkillAgent, _ skills: [SkillSummary]) -> SkillAgentSnapshot {
        SkillAgentSnapshot(agent: agent, root: "/\(agent.rawValue)", exists: true, skills: skills)
    }

    @Test func mergesTheSameSkillAcrossAgents() {
        let groups = SkillGroup.group([
            snapshot(.claude, [skill(.claude, "brand"), skill(.claude, "lousa")]),
            snapshot(.codex, [skill(.codex, "brand")]),
        ])
        #expect(groups.map(\.name) == ["brand", "lousa"])
        #expect(groups[0].agents == [.claude, .codex])
    }

    @Test func neverOffersTheSharedCopyForABulkRemove() {
        let groups = SkillGroup.group([
            snapshot(.claude, [skill(.claude, "brand", linked: true)]),
            snapshot(.shared, [skill(.shared, "brand")]),
        ])
        #expect(groups[0].agents == [.claude])
        #expect(groups[0].removable.map(\.agent) == [.claude])
        #expect(groups[0].sharedEntry?.agent == .shared)
    }

    @Test func bundledCopiesAreNotRemovableAndTheGroupIsBundledOnlyWhenAllAre() {
        let mixed = SkillGroup.group([
            snapshot(.codex, [skill(.codex, "imagegen", bundled: true)]),
            snapshot(.claude, [skill(.claude, "imagegen")]),
        ])
        #expect(mixed[0].removable.map(\.agent) == [.claude])
        #expect(!mixed[0].bundled)
        let only = SkillGroup.group([snapshot(.codex, [skill(.codex, "imagegen", bundled: true)])])
        #expect(only[0].bundled)
        #expect(only[0].removable.isEmpty)
    }

    @Test func takesTheFirstNonEmptyDescription() {
        let groups = SkillGroup.group([
            snapshot(.claude, [skill(.claude, "brand")]),
            snapshot(.codex, [skill(.codex, "brand", description: "Brand system")]),
        ])
        #expect(groups[0].description == "Brand system")
    }

    @Test func filtersByQueryAndAgent() {
        let groups = SkillGroup.group([
            snapshot(.claude, [skill(.claude, "brand", description: "Visual Identity")]),
            snapshot(.codex, [skill(.codex, "motion")]),
        ])
        #expect(groups.filter { $0.matches("IDENT") }.map(\.name) == ["brand"])
        #expect(groups.filter { $0.matches("  ") }.count == 2)
        #expect(groups.filter { $0.isInstalled(for: .codex) }.map(\.name) == ["motion"])
        #expect(groups.filter { $0.isInstalled(for: nil) }.count == 2)
    }
}
