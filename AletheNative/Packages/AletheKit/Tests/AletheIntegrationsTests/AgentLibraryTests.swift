import Foundation
import Testing
@testable import AletheIntegrations

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "AgentLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct Fixture {
    let root = temporaryDirectory()
    var project: URL { root.appending(path: "project", directoryHint: .isDirectory) }
    var scope: AgentLibraryScope { .project(project) }
    var agents: URL { scope.agentsDirectory }
    var store: AgentLibraryStore {
        AgentLibraryStore(writer: ConfigFileWriter(profileDirectory: root.appending(path: "profile")))
    }

    func put(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: agents.appending(path: name))
    }

    func text(_ name: String) -> String? {
        try? String(contentsOf: agents.appending(path: name), encoding: .utf8)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: agents.appending(path: name).path)
    }
}

private func frontmatterValue(_ content: String, _ field: String) -> String? {
    guard content.hasPrefix("---\n"), let end = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else {
        return nil
    }
    let block = content[content.index(content.startIndex, offsetBy: 4)..<end.lowerBound]
    for line in block.split(separator: "\n") where line.hasPrefix("\(field):") {
        return line.dropFirst(field.count + 1).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

@Suite struct AgentLibraryCatalogTests {
    /// Upstream `agentLibrary.test.ts`: frontmatter matches the metadata and the marker closes the file.
    @Test(arguments: AgentLibraryCatalog.templates + EconomyAgents.templates)
    func templateMetadataIsConsistent(_ template: AgentTemplate) {
        #expect(frontmatterValue(template.content, "name") == template.name)
        #expect(frontmatterValue(template.content, "description")?.isEmpty == false)
        #expect(frontmatterValue(template.content, "model")?.isEmpty == false)
        #expect(!template.summary.trimmingCharacters(in: .whitespaces).isEmpty)
        let marker = template.category == .economy ? AletheAgentMarker.economy : AletheAgentMarker.library
        #expect(template.content.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(marker))
        #expect(AletheAgentMarker.isAletheGenerated(template.content))
    }

    @Test func namesAreUniqueAndFileSystemSafe() {
        let names = (AgentLibraryCatalog.templates + EconomyAgents.templates).map(\.name)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }, "\(name)")
            #expect(AgentLibraryStore.isValidName(name))
        }
    }

    @Test func economyAgentsAreHaiku() {
        for template in EconomyAgents.templates {
            #expect(frontmatterValue(template.content, "model") == "haiku")
            #expect(template.cost == .cheap)
        }
    }

    @Test func guardCommandFollowsTheScope() {
        let project = EconomyAgents.files(for: .project(URL(filePath: "/p"))).first { $0.fileName == "codex-executor.md" }
        let user = EconomyAgents.files(for: .user(home: URL(filePath: "/h"))).first { $0.fileName == "codex-executor.md" }
        #expect(project?.content.contains("command: node .claude/agents/codex-only-guard.cjs") == true)
        #expect(user?.content.contains("command: node \"$HOME/.claude/agents/codex-only-guard.cjs\"") == true)
        let guardFile = EconomyAgents.files(for: .project(URL(filePath: "/p"))).first { $0.fileName == EconomyAgents.guardFileName }
        #expect(guardFile.map { EconomyAgents.isOwned($0.content) } == true)
        #expect(guardFile?.content.contains(#"/^\s*codex\s+exec\b/"#) == true)
    }

    @Test func scopesPointAtClaudeAgents() {
        #expect(AgentLibraryScope.project(URL(filePath: "/p")).agentsDirectory.path == "/p/.claude/agents")
        #expect(AgentLibraryScope.user(home: URL(filePath: "/Users/me")).agentsDirectory.path == "/Users/me/.claude/agents")
        #expect(AgentLibraryScope.project(URL(filePath: "/p")).backupSlot != AgentLibraryScope.user(home: URL(filePath: "/p")).backupSlot)
    }
}

@Suite struct AgentLibraryMarkerTests {
    @Test func recognizesBothWordings() {
        #expect(AletheAgentMarker.isAletheGenerated("x\n<!-- gerado pelo Alethe (biblioteca) — seguro deletar -->\n"))
        #expect(AletheAgentMarker.isAletheGenerated("x\n<!-- gerado pelo Alethe (modo economia) — seguro deletar -->\n"))
        #expect(AletheAgentMarker.isAletheGenerated("x\n\(AletheAgentMarker.library)\n"))
        #expect(!AletheAgentMarker.isAletheGenerated("---\nname: mine\n---\nMy own agent.\n"))
    }

    @Test func recognizesUpstreamGuardWithoutMarker() {
        let upstream = "console.error('Bloqueado: o codex-executor só pode rodar `codex exec ...`.')"
        #expect(EconomyAgents.isOwned(upstream))
        #expect(!EconomyAgents.isOwned("console.log('mine')"))
    }

    @Test func listsAgentsWithTheirOrigin() throws {
        let fixture = Fixture()
        try fixture.put("mine.md", "---\nname: mine\n---\n")
        try fixture.put("old.md", "<!-- gerado pelo Alethe (biblioteca) — seguro deletar -->")
        try fixture.put("notes.txt", "ignored")
        let installed = fixture.store.installed(in: fixture.scope)
        #expect(installed.map(\.name) == ["mine", "old"])
        #expect(installed.map(\.fromAlethe) == [false, true])
    }

    @Test func missingFolderListsNothing() {
        #expect(Fixture().store.installed(in: Fixture().scope).isEmpty)
    }
}

@Suite struct AgentLibraryInstallTests {
    private let template = AgentLibraryCatalog.template(named: "qa-reviewer")!

    @Test func installsAndUninstalls() throws {
        let fixture = Fixture()
        let change = try fixture.store.install(template, in: fixture.scope)
        #expect(fixture.text("qa-reviewer.md") == template.content)
        #expect(change.edits.count == 1 && change.edits[0].previous == nil)
        #expect(fixture.store.installed(in: fixture.scope).first?.fromAlethe == true)

        let removal = try fixture.store.uninstall("qa-reviewer", in: fixture.scope)
        #expect(!fixture.exists("qa-reviewer.md"))
        #expect(removal.edits.first?.current == nil)
    }

    @Test func reinstallingIdenticalContentChangesNothing() throws {
        let fixture = Fixture()
        try fixture.store.install(template, in: fixture.scope)
        #expect(try fixture.store.install(template, in: fixture.scope).isEmpty)
    }

    @Test func overwritesAnAletheFileWithoutAsking() throws {
        let fixture = Fixture()
        try fixture.put("qa-reviewer.md", "old\n<!-- gerado pelo Alethe (biblioteca) — seguro deletar -->\n")
        try fixture.store.install(template, in: fixture.scope)
        #expect(fixture.text("qa-reviewer.md") == template.content)
        let backups = fixture.store.writer.backups(in: fixture.scope.backupSlot)
        #expect(backups.count == 1, "the previous file is backed up")
    }

    @Test func foreignFileIsAConflictUntilForced() throws {
        let fixture = Fixture()
        try fixture.put("qa-reviewer.md", "my own reviewer")
        #expect(throws: AgentLibraryError.conflict("qa-reviewer")) {
            try fixture.store.install(template, in: fixture.scope)
        }
        #expect(fixture.text("qa-reviewer.md") == "my own reviewer")
        try fixture.store.install(template, in: fixture.scope, overwriteForeign: true)
        #expect(fixture.text("qa-reviewer.md") == template.content)
    }

    @Test func foreignFileIsRemovedOnlyWhenForced() throws {
        let fixture = Fixture()
        try fixture.put("mine.md", "my agent")
        #expect(throws: AgentLibraryError.notAlethe("mine")) {
            try fixture.store.uninstall("mine", in: fixture.scope)
        }
        #expect(fixture.exists("mine.md"))
        try fixture.store.uninstall("mine", in: fixture.scope, force: true)
        #expect(!fixture.exists("mine.md"))
        #expect(fixture.store.writer.backups(in: fixture.scope.backupSlot).count == 1)
    }

    @Test func uninstallingAMissingAgentIsANoOp() throws {
        let fixture = Fixture()
        #expect(try fixture.store.uninstall("ghost", in: fixture.scope).isEmpty)
    }

    @Test(arguments: ["", "../escape", "a/b", "a\\b", ".hidden"])
    func refusesInvalidNames(_ name: String) {
        let fixture = Fixture()
        #expect(throws: AgentLibraryError.invalidName(name)) {
            try fixture.store.uninstall(name, in: fixture.scope, force: true)
        }
    }

    @Test func revertUndoesAndRedoes() throws {
        let fixture = Fixture()
        try fixture.put("qa-reviewer.md", "previous <!-- generated by Alethe (library) — safe to delete -->")
        let change = try fixture.store.install(template, in: fixture.scope)
        let redo = try fixture.store.revert(change, backupSlot: fixture.scope.backupSlot)
        #expect(fixture.text("qa-reviewer.md") == "previous <!-- generated by Alethe (library) — safe to delete -->")
        try fixture.store.revert(redo, backupSlot: fixture.scope.backupSlot)
        #expect(fixture.text("qa-reviewer.md") == template.content)
    }

    @Test func revertOfAFreshInstallRemovesTheFile() throws {
        let fixture = Fixture()
        let change = try fixture.store.install(template, in: fixture.scope)
        try fixture.store.revert(change, backupSlot: fixture.scope.backupSlot)
        #expect(!fixture.exists("qa-reviewer.md"))
    }

    @Test func revertRefusesAfterAnOutsideEdit() throws {
        let fixture = Fixture()
        let change = try fixture.store.install(template, in: fixture.scope)
        try fixture.put("qa-reviewer.md", "edited by hand")
        #expect(throws: AgentLibraryError.file(.changedSinceRead(fixture.agents.appending(path: "qa-reviewer.md")))) {
            try fixture.store.revert(change, backupSlot: fixture.scope.backupSlot)
        }
        #expect(fixture.text("qa-reviewer.md") == "edited by hand")
    }
}

@Suite struct EconomyModeTests {
    @Test func togglesOnAndOff() throws {
        let fixture = Fixture()
        #expect(!fixture.store.economyEnabled(in: fixture.scope))
        let on = try fixture.store.setEconomy(true, in: fixture.scope)
        #expect(on.edits.count == 4 && on.skipped.isEmpty)
        #expect(fixture.store.economyEnabled(in: fixture.scope))
        for file in EconomyAgents.files(for: fixture.scope) {
            #expect(fixture.text(file.fileName) == file.content)
        }

        let off = try fixture.store.setEconomy(false, in: fixture.scope)
        #expect(off.edits.count == 4)
        #expect(!fixture.store.economyEnabled(in: fixture.scope))
        #expect(fixture.store.installed(in: fixture.scope).isEmpty)
    }

    @Test func keepsUserFilesAndReportsThem() throws {
        let fixture = Fixture()
        try fixture.put("haiku-summarizer.md", "my own summarizer")
        let on = try fixture.store.setEconomy(true, in: fixture.scope)
        #expect(on.skipped == ["haiku-summarizer.md"])
        #expect(fixture.text("haiku-summarizer.md") == "my own summarizer")

        let off = try fixture.store.setEconomy(false, in: fixture.scope)
        #expect(off.skipped == ["haiku-summarizer.md"])
        #expect(fixture.text("haiku-summarizer.md") == "my own summarizer")
        #expect(!fixture.exists("haiku-mechanic.md"))
    }

    @Test func replacesAndRemovesUpstreamFiles() throws {
        let fixture = Fixture()
        let marker = "<!-- gerado pelo Alethe (modo economia) — seguro deletar -->"
        try fixture.put("haiku-resumidor.md", "resumidor\n\(marker)\n")
        try fixture.put("haiku-mecanico.md", "mecanico\n\(marker)\n")
        try fixture.put("codex-executor.md", "executor\n\(marker)\n")
        try fixture.put("codex-only-guard.cjs", "console.error('Bloqueado: o codex-executor só pode rodar `codex exec ...`.')")
        #expect(!fixture.store.economyEnabled(in: fixture.scope))

        try fixture.store.setEconomy(true, in: fixture.scope)
        #expect(!fixture.exists("haiku-resumidor.md") && !fixture.exists("haiku-mecanico.md"))
        #expect(fixture.text("codex-only-guard.cjs")?.contains("Blocked:") == true)
        #expect(fixture.store.economyEnabled(in: fixture.scope))

        try fixture.store.setEconomy(false, in: fixture.scope)
        #expect(fixture.store.installed(in: fixture.scope).isEmpty)
        #expect(!fixture.exists("codex-only-guard.cjs"))
    }

    @Test func turningOffRemovesUpstreamFilesToo() throws {
        let fixture = Fixture()
        try fixture.put("haiku-resumidor.md", "<!-- gerado pelo Alethe (modo economia) — seguro deletar -->")
        let off = try fixture.store.setEconomy(false, in: fixture.scope)
        #expect(off.edits.count == 1)
        #expect(!fixture.exists("haiku-resumidor.md"))
    }

    @Test func libraryAgentsSurviveEconomyOff() throws {
        let fixture = Fixture()
        try fixture.store.install(AgentLibraryCatalog.template(named: "docs-writer")!, in: fixture.scope)
        try fixture.store.setEconomy(true, in: fixture.scope)
        try fixture.store.setEconomy(false, in: fixture.scope)
        #expect(fixture.store.installed(in: fixture.scope).map(\.name) == ["docs-writer"])
    }

    @Test func revertingEconomyOnRestoresTheFolder() throws {
        let fixture = Fixture()
        let change = try fixture.store.setEconomy(true, in: fixture.scope)
        try fixture.store.revert(change, backupSlot: fixture.scope.backupSlot)
        #expect(!fixture.store.economyEnabled(in: fixture.scope))
        #expect(fixture.store.installed(in: fixture.scope).isEmpty)
    }
}

@Suite struct ConfigFileRemoveTests {
    @Test func removesWithABackupAndRefusesAfterAnOutsideEdit() throws {
        let root = temporaryDirectory()
        let writer = ConfigFileWriter(profileDirectory: root.appending(path: "profile"))
        let slot = ConfigBackupSlot(agent: "claude", kind: "agents_project")
        let url = root.appending(path: "a.md")
        try Data("one".utf8).write(to: url)
        let stale = try writer.read(url)
        try Data("two".utf8).write(to: url)
        #expect(throws: ConfigFileError.changedSinceRead(url)) {
            try writer.remove(over: stale, backupSlot: slot)
        }
        let report = try writer.remove(over: writer.read(url), backupSlot: slot)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(report.backup.flatMap { try? Data(contentsOf: $0.url) } == Data("two".utf8))
    }

    @Test func removingAMissingFileIsANoOp() throws {
        let root = temporaryDirectory()
        let writer = ConfigFileWriter(profileDirectory: root)
        let report = try writer.remove(over: writer.read(root.appending(path: "none")), backupSlot: nil)
        #expect(report.backup == nil)
    }
}
