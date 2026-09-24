import Foundation
import Testing
@testable import AletheDocuments

@Suite struct DiffParserTests {
    static let sample = """
    diff --git a/Sources/a.swift b/Sources/a.swift
    index 1111111..2222222 100644
    --- a/Sources/a.swift
    +++ b/Sources/a.swift
    @@ -10,4 +10,5 @@ struct A {
     let one = 1
    -let two = 2
    +let two = 22
    +let three = 3
     let four = 4
    \\ No newline at end of file
    diff --git a/old.txt b/new.txt
    similarity index 90%
    rename from old.txt
    rename to new.txt

    """

    @Test func filesHunksAndLineNumbers() throws {
        let document = DiffParser.parse(Self.sample)
        #expect(document.files.map(\.path) == ["Sources/a.swift", "new.txt"])
        let hunk = try #require(document.files.first?.hunks.first)
        #expect(hunk.header.hasPrefix("@@ -10,4 +10,5 @@"))
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .added, .added, .context, .note])
        #expect(hunk.lines[0].oldNumber == 10 && hunk.lines[0].newNumber == 10)
        #expect(hunk.lines[1].oldNumber == 11 && hunk.lines[1].newNumber == nil)
        #expect(hunk.lines[2].newNumber == 11 && hunk.lines[3].newNumber == 12)
        #expect(hunk.lines[4].oldNumber == 12 && hunk.lines[4].newNumber == 13)
        #expect(hunk.lines[2].text == "let two = 22")
        #expect(document.files[1].hunks.isEmpty)
        #expect(document.files[1].header.contains("rename to new.txt"))
    }

    @Test func splitPairsRemovalsWithAdditions() throws {
        let hunk = try #require(DiffParser.parse(Self.sample).files.first?.hunks.first)
        let rows = DiffParser.split(hunk)
        #expect(rows.count == 5)
        #expect(rows[1].left?.text == "let two = 2" && rows[1].right?.text == "let two = 22")
        #expect(rows[2].left == nil && rows[2].right?.text == "let three = 3")
        #expect(rows[0].left == rows[0].right, "context sits on both sides")
    }

    @Test func emptyAndHeaderParsing() {
        #expect(DiffParser.parse("").isEmpty)
        #expect(DiffParser.hunkStarts("@@ -3 +4,2 @@") == (3, 4))
        #expect(DiffParser.gitPath("diff --git a/x y/z b/x y/z") == "x y/z")
    }
}

@Suite struct GitDiffTests {
    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", folder.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = nil
        try process.run()
        process.waitUntilExit()
    }

    @Test func workingTreeStagedAndErrors() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "alethe-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "a.txt")
        try Data("one\n".utf8).write(to: file)
        try git(["init", "-q"], in: folder)
        try git(["add", "."], in: folder)
        try git(["commit", "-q", "-m", "init"], in: folder)
        try Data("one\ntwo\n".utf8).write(to: file)

        let unstaged = try await GitDiff.run(folder: folder.path, path: nil, staged: false).get()
        #expect(DiffParser.parse(unstaged).files.first?.hunks.first?.lines.last?.text == "two")
        #expect(try await GitDiff.run(folder: folder.path, path: nil, staged: true).get().isEmpty)
        try git(["add", "a.txt"], in: folder)
        #expect(try await !GitDiff.run(folder: folder.path, path: "a.txt", staged: true).get().isEmpty)

        let outside = FileManager.default.temporaryDirectory.appending(path: "alethe-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let result = await GitDiff.run(folder: outside.path, path: nil, staged: false)
        #expect(result == .failure(.notARepository))
    }
}
