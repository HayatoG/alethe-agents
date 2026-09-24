import Foundation
import Testing
@testable import AletheDocuments

@Suite struct MarkdownBlocksTests {
    private let base = URL(filePath: "/repo/docs", directoryHint: .isDirectory)

    @Test func headingsParagraphsAndInlineStyles() throws {
        let blocks = MarkdownBlocks.parse("# Title\n\nSome *soft* and **bold** `code` ~~gone~~.", base: base)
        #expect(blocks.count == 2)
        guard case .heading(1, let title) = blocks[0], case .paragraph(let text) = blocks[1] else {
            Issue.record("unexpected blocks \(blocks)")
            return
        }
        #expect(String(title.characters) == "Title")
        #expect(String(text.characters) == "Some soft and bold code gone.")
        let intents = text.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains(.emphasized))
        #expect(intents.contains(.stronglyEmphasized))
        #expect(intents.contains(.code))
        #expect(intents.contains(.strikethrough))
    }

    @Test func gfmTablesAndTaskLists() {
        let markdown = """
        | Name | Qty |
        |:-----|----:|
        | a | 1 |
        | b |

        - [x] done
        - [ ] todo
        - plain
        """
        let blocks = MarkdownBlocks.parse(markdown, base: base)
        guard case .table(let header, let alignments, let rows) = blocks.first,
              case .list(false, _, let items) = blocks.last else {
            Issue.record("unexpected blocks \(blocks)")
            return
        }
        #expect(header.map { String($0.characters) } == ["Name", "Qty"])
        #expect(alignments == [.leading, .trailing])
        #expect(rows.count == 2)
        #expect(rows[1].count == 2, "short rows are padded")
        #expect(items.map(\.checkbox) == [true, false, nil])
    }

    @Test func codeQuotesRulesAndHTML() {
        let blocks = MarkdownBlocks.parse("```swift\nlet a = 1\n```\n\n> quoted\n\n---\n\n<div>raw</div>", base: base)
        #expect(blocks.count == 4)
        #expect(blocks[0] == .code(language: "swift", code: "let a = 1"))
        guard case .quote(let inner) = blocks[1] else { Issue.record("no quote"); return }
        #expect(inner.count == 1)
        #expect(blocks[2] == .rule)
        #expect(blocks[3] == .html("<div>raw</div>"))
    }

    @Test func orderedListsKeepTheirStart() {
        guard case .list(true, let start, let items) = MarkdownBlocks.parse("3. c\n4. d").first else {
            Issue.record("no ordered list")
            return
        }
        #expect(start == 3)
        #expect(items.count == 2)
    }

    @Test func relativeLinksAndImagesResolveAgainstTheFile() {
        #expect(MarkdownBlocks.resolve("guide.md", base: base) == URL(filePath: "/repo/docs/guide.md"))
        #expect(MarkdownBlocks.resolve("../README.md#top", base: base) == URL(filePath: "/repo/README.md"))
        #expect(MarkdownBlocks.resolve("https://example.com/x", base: base) == URL(string: "https://example.com/x"))
        #expect(MarkdownBlocks.resolve("/abs/a.png", base: base) == URL(filePath: "/abs/a.png"))
        #expect(MarkdownBlocks.resolve("#section", base: base) == nil)
        guard case .image(let source, let alt) = MarkdownBlocks.parse("![Logo](img/logo.png)", base: base).first else {
            Issue.record("no image")
            return
        }
        #expect(source == URL(filePath: "/repo/docs/img/logo.png"))
        #expect(alt == "Logo")
        guard case .paragraph(let text) = MarkdownBlocks.parse("See [guide](guide.md).", base: base).first else {
            Issue.record("no paragraph")
            return
        }
        #expect(text.runs.compactMap(\.link) == [URL(filePath: "/repo/docs/guide.md")])
    }
}

@MainActor
@Suite struct MarkdownFileTests {
    private func temporaryFile(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "alethe-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "README.md")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<60 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    @Test func loadsEditsAndSaves() async throws {
        let url = try temporaryFile("# One")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = MarkdownFile(path: url.path, watch: false)
        #expect(await waitFor { file.isLoaded })
        #expect(file.source == "# One")
        file.beginEditing()
        file.draft = "# Two"
        #expect(file.hasUnsavedChanges)
        #expect(file.save())
        #expect(!file.isEditing)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Two")
        #expect(file.blocks.count == 1)
    }

    @Test func reloadsWhenAnotherProgramReplacesTheFile() async throws {
        let url = try temporaryFile("first")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = MarkdownFile(path: url.path)
        defer { file.close() }
        #expect(await waitFor { file.source == "first" })
        try await Task.sleep(for: .milliseconds(100))
        // An atomic save (rename over the file), the way editors and agents write.
        try Data("second".utf8).write(to: url, options: .atomic)
        #expect(await waitFor { file.source == "second" })
        try await Task.sleep(for: .milliseconds(100))
        try Data("third".utf8).write(to: url, options: .atomic)
        #expect(await waitFor { file.source == "third" }, "still watching after a replace")
    }

    @Test func editsSurviveChangesOnDisk() async throws {
        let url = try temporaryFile("disk")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = MarkdownFile(path: url.path, watch: false)
        #expect(await waitFor { file.isLoaded })
        file.beginEditing()
        file.draft = "mine"
        try Data("theirs".utf8).write(to: url)
        file.reload()
        #expect(await waitFor { file.source == "theirs" })
        #expect(file.draft == "mine", "a reload never replaces a draft")
    }

    @Test func missingFilesReportAnError() async {
        let file = MarkdownFile(path: "/nonexistent/\(UUID().uuidString).md", watch: false)
        #expect(await waitFor { file.isLoaded })
        #expect(file.loadError != nil)
    }
}
