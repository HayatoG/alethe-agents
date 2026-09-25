import AletheGit
import Foundation
import Testing
@testable import AletheFiles

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("alethe-files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.standardizedFileURL
}

private func touch(_ url: URL, _ text: String = "") {
    FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
}

@Suite @MainActor struct FileTreeTests {
    @Test func listsFoldersFirstCaseInsensitiveAndKeepsUpstreamEntries() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in ["zeta", "Alpha", ".git", "node_modules"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: false)
        }
        for file in ["b.txt", "A.md", ".env", ".DS_Store"] { touch(root.appendingPathComponent(file), "hi") }

        let tree = FileTree(root: root)
        try tree.reload()
        #expect(tree.rootNodes.map(\.name) == [".git", "Alpha", "node_modules", "zeta", ".env", "A.md", "b.txt"])
        #expect(tree.rootNodes.first { $0.name == "b.txt" }?.size == 2)
        #expect(tree.rootNodes.first { $0.name == "zeta" }?.size == nil)

        tree.filter = FileTreeFilter(showDotfiles: false)
        try tree.reload()
        #expect(tree.rootNodes.map(\.name) == ["Alpha", "node_modules", "zeta", "A.md", "b.txt"])
    }

    @Test func loadsChildrenLazilyAndRefreshesExpandedDirectories() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: false)
        touch(src.appendingPathComponent("main.swift"))
        touch(root.appendingPathComponent("README.md"))

        let tree = FileTree(root: root)
        try tree.reload()
        #expect(tree.children(of: src) == nil)
        #expect(tree.visibleRows().map(\.node.name) == ["src", "README.md"])

        try tree.expand(src)
        #expect(tree.children(of: src)?.map(\.name) == ["main.swift"])
        #expect(tree.visibleRows().map { "\($0.depth):\($0.node.name)" } == ["0:src", "1:main.swift", "0:README.md"])

        touch(src.appendingPathComponent("app.swift"))
        try tree.reload()
        #expect(tree.children(of: src)?.map(\.name) == ["app.swift", "main.swift"])

        tree.collapse(src)
        #expect(tree.visibleRows().count == 2)
        try tree.toggle(src)
        #expect(tree.isExpanded(src))

        try FileManager.default.removeItem(at: src)
        try tree.reload()
        #expect(!tree.isExpanded(src))
        #expect(tree.rootNodes.map(\.name) == ["README.md"])
    }

    @Test func followReloadsOnSignal() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = FileTree(root: root)
        try tree.reload()
        touch(root.appendingPathComponent("new.txt"))
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        continuation.yield()
        continuation.finish()
        await tree.follow(stream)
        #expect(tree.rootNodes.map(\.name) == ["new.txt"])
    }
}

@Suite struct FileIconTests {
    @Test(arguments: [
        (".gitignore", "arrow.triangle.branch"),
        ("Dockerfile", "shippingbox"),
        ("docker-compose.yml", "shippingbox"),
        (".env.local", "key"),
        ("package.json", "curlybraces"),
        ("Cargo.toml", "slider.horizontal.3"),
        ("data.sqlite", "cylinder"),
        ("build.sh", "terminal"),
        ("main.RS", "chevron.left.forwardslash.chevron.right"),
        ("logo.png", "photo"),
        ("clip.mov", "film"),
        ("song.flac", "waveform"),
        ("sheet.csv", "tablecells"),
        ("pack.tar", "archivebox"),
        ("README.md", "doc.text"),
        ("LICENSE", "doc"),
        (".bashrc", "doc"),
        ("file.unknown", "doc"),
    ])
    func mapsFileNames(name: String, symbol: String) {
        #expect(FileIcons.symbolName(forFileName: name) == symbol)
    }

    @Test func directoriesUseFolderSymbol() {
        #expect(FileNode(url: URL(fileURLWithPath: "/x"), name: "x", isDirectory: true).iconName == "folder")
    }
}

@Suite struct FilePaneKindTests {
    @Test(arguments: [
        ("notes.md", FilePaneKind.markdown),
        ("doc.MDX", .markdown),
        ("shot.PNG", .image),
        ("icon.svg", .image),
        ("demo.mkv", .video),
        ("demo.mp4:12", .video),
        ("index.html", .web),
        ("manual.pdf", .web),
        ("main.swift:10:4", .text),
        ("Makefile", .text),
    ])
    func classifies(path: String, kind: FilePaneKind) {
        #expect(FilePaneKind.forFile(path) == kind)
    }

    @Test func directoriesHaveNoPane() {
        #expect(FileNode(url: URL(fileURLWithPath: "/x"), name: "x", isDirectory: true).paneKind == nil)
    }
}

@Suite struct GitBadgeTests {
    private static let status = GitParsers.parseStatus([
        "# branch.head main",
        "1 .M N... 100644 100644 100644 aaa bbb src/app/view.swift",
        "1 A. N... 000000 100644 100644 000 ccc src/new.swift",
        "1 M. N... 100644 100644 100644 aaa bbb docs/guide.md",
        "1 MD N... 100644 100644 100644 aaa bbb docs/gone.md",
        "1 D. N... 100644 000000 000000 aaa 000 old.txt",
        "2 R. N... 100644 100644 100644 aaa aaa R100 lib/renamed.swift", "lib/original.swift",
        "u UU N... 100644 100644 100644 100644 a b c src/app/Conflict.swift",
        "? scratch/",
        "? notes.txt",
        "! build/",
    ].joined(separator: "\0") + "\0")

    private let root = URL(fileURLWithPath: "/repo")
    private var index: GitBadgeIndex { GitBadgeIndex(status: Self.status, repoRoot: root) }

    private func file(_ path: String) -> GitBadge? {
        index.badge(for: root.appendingPathComponent(path), isDirectory: false)
    }

    private func folder(_ path: String) -> GitBadge? {
        index.badge(for: root.appendingPathComponent(path), isDirectory: true)
    }

    @Test func mapsEntriesToFileBadges() {
        #expect(file("src/app/view.swift") == .modified)
        #expect(file("src/new.swift") == .added)
        #expect(file("docs/guide.md") == .stagedModified)
        #expect(file("docs/gone.md") == .stagedModified) // staged M outranks unstaged D
        #expect(file("old.txt") == .deleted)
        #expect(file("lib/renamed.swift") == .renamed)
        #expect(file("src/app/conflict.swift") == .conflict) // case-insensitive
        #expect(file("notes.txt") == .untracked)
        #expect(file("build") == nil)
        #expect(file("clean.swift") == nil)
    }

    @Test func foldersAggregateStrongestChild() {
        #expect(folder("src/app") == .conflict)
        #expect(folder("src") == .conflict)
        #expect(folder("docs") == .stagedModified)
        #expect(folder("lib") == .renamed)
        #expect(folder("scratch") == .untracked)
        #expect(folder("build") == nil)
        #expect(index.badge(for: root, isDirectory: true) == .conflict)
        #expect(index.badge(for: URL(fileURLWithPath: "/elsewhere/src"), isDirectory: true) == nil)
        #expect(index.badge(for: URL(fileURLWithPath: "/repository/src"), isDirectory: true) == nil)
        #expect(GitBadge.conflict.letter == "!" && GitBadge.untracked.letter == "U")
    }
}

@Suite struct FileOperationTests {
    @Test(arguments: ["", "  ", ".", "..", "a/b", "a\0b", String(repeating: "x", count: 256)])
    func rejectsInvalidNames(name: String) {
        #expect(throws: FileOperationError.invalidName) { try FileOperations.validateName(name) }
    }

    @Test func trimsValidNames() throws {
        #expect(try FileOperations.validateName("  notes.md ") == "notes.md")
    }

    @Test func createsRenamesAndTrashes() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = try FileOperations.createFile(named: "a.txt", in: root)
        let folder = try FileOperations.createFolder(named: "dir", in: root)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(throws: FileOperationError.alreadyExists) { try FileOperations.createFile(named: "a.txt", in: root) }
        #expect(throws: FileOperationError.alreadyExists) { try FileOperations.createFolder(named: "dir", in: root) }

        let renamed = try FileOperations.rename(file, to: "b.txt")
        #expect(renamed.lastPathComponent == "b.txt")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(throws: FileOperationError.alreadyExists) { try FileOperations.rename(renamed, to: "dir") }
        #expect(throws: FileOperationError.invalidName) { try FileOperations.rename(renamed, to: "../x") }
        #expect(throws: FileOperationError.notFound) { try FileOperations.rename(file, to: "c.txt") }

        let caseOnly = try FileOperations.rename(renamed, to: "B.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("B.txt"))

        let outcome = try FileOperations.moveToTrash(caseOnly)
        if case .trashed(let location) = outcome, let location {
            try? FileManager.default.removeItem(at: location)
        }
        #expect(!FileManager.default.fileExists(atPath: caseOnly.path))

        try FileOperations.deletePermanently(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(throws: FileOperationError.rootNotModifiable) { try FileOperations.deletePermanently(URL(fileURLWithPath: "/")) }
    }

    @Test func recognizesTrashUnavailable() {
        #expect(FileOperations.isTrashUnavailable(CocoaError(.featureUnsupported)))
        #expect(!FileOperations.isTrashUnavailable(CocoaError(.fileNoSuchFile)))
    }
}
