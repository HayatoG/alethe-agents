import Foundation
import Testing
@testable import AletheFoundation

/// Upstream `cli_launch.rs` cases, plus macOS user-default arguments.
@Suite struct CLILaunchTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "alethe-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CLILaunch.canonical(root)
    }

    @Test func readsTheFlagAfterArgv0() {
        #expect(CLILaunch.pathArgument(in: ["alethe", "--open-path", "/tmp/x"]) == "/tmp/x")
    }

    @Test func readsTheInlineFlagForm() {
        #expect(CLILaunch.pathArgument(in: ["alethe", "--open-path=/tmp/x"]) == "/tmp/x")
    }

    @Test func readsABarePositional() {
        #expect(CLILaunch.pathArgument(in: ["alethe", "/tmp/x"]) == "/tmp/x")
    }

    @Test func skipsFinderProcessSerialNumbers() {
        #expect(CLILaunch.pathArgument(in: ["alethe", "-psn_0_1234"]) == nil)
        #expect(CLILaunch.pathArgument(in: ["alethe", "-psn_0_1234", "/tmp/x"]) == "/tmp/x")
    }

    @Test func userDefaultArgumentsTakeTheirValue() {
        #expect(CLILaunch.pathArgument(in: ["Alethe", "-AletheDataRoot", "/private/tmp/data"]) == nil)
        #expect(CLILaunch.pathArgument(in: ["Alethe", "-NSDocumentRevisionsDebugMode", "YES",
                                            "-AppleLanguages", "(en)", "--open-path", "/tmp/x"]) == "/tmp/x")
        #expect(CLILaunch.pathArgument(in: ["Alethe", "--verbose", "/tmp/x"]) == "/tmp/x")
    }

    @Test func noArgumentsMeansNoTarget() {
        #expect(CLILaunch.pathArgument(in: ["alethe"]) == nil)
        #expect(CLILaunch.pathArgument(in: ["alethe", "--open-path"]) == nil)
        #expect(CLILaunch.resolveTarget(arguments: ["alethe"], cwd: URL(filePath: "/")) == nil)
        #expect(CLILaunch.resolveTarget(arguments: ["alethe", "--open-path", "  "], cwd: URL(filePath: "/")) == nil)
    }

    @Test func dotResolvesAgainstTheCallersFolder() throws {
        let cwd = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: cwd) }
        #expect(CLILaunch.resolveTarget(arguments: ["alethe", "."], cwd: cwd)?.path == cwd.path)
    }

    @Test func relativePathResolvesAgainstTheCallersFolder() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let nested = base.appending(path: "rel")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(CLILaunch.resolveTarget(arguments: ["alethe", "rel"], cwd: base)?.path == nested.path)
        #expect(CLILaunch.resolveTarget(arguments: ["alethe", "rel/../rel/"], cwd: base)?.path == nested.path)
    }

    @Test func aFileResolvesToItsFolder() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appending(path: "README.md")
        try Data("x".utf8).write(to: file)
        #expect(CLILaunch.resolveTarget(arguments: ["alethe", file.path], cwd: URL(filePath: "/"))?.path == base.path)
        #expect(CLILaunch.directory(for: file)?.path == base.path)
    }

    @Test func aMissingPathResolvesToNil() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "alethe-cli-missing-\(UUID().uuidString)")
        #expect(CLILaunch.resolveTarget(arguments: ["alethe", missing.path], cwd: URL(filePath: "/")) == nil)
    }

    @Test func symlinksAndPrivatePrefixCompareEqual() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
        #expect(CLILaunch.samePath(link.path, base.path))
        #expect(CLILaunch.samePath("/private/tmp", "/tmp/"))
        #expect(!CLILaunch.samePath("/tmp", "/usr"))
    }

    @Test func matchPrefersTheGivenProject() {
        let candidates: [(id: String, folder: String)] = [("a", "/tmp"), ("b", "/usr"), ("c", "/private/tmp")]
        #expect(CLILaunch.match(folder: "/private/tmp/", in: candidates) == "a")
        #expect(CLILaunch.match(folder: "/tmp", in: candidates, preferred: "c") == "c")
        #expect(CLILaunch.match(folder: "/tmp", in: candidates, preferred: "b") == "a")
        #expect(CLILaunch.match(folder: "/var/empty", in: candidates) == nil)
    }
}
