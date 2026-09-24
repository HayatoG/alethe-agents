import Foundation
import Testing
@testable import AletheTerminal

@Suite struct TerminalLinkTests {
    /// /repo is a directory holding README.md and src/main.swift.
    private func kind(_ path: String) -> Bool? {
        switch path {
        case "/repo", "/repo/src", "/Users/me": true
        case "/repo/README.md", "/repo/src/main.swift", "/Users/me/notes.md", "/repo/my file.md": false
        default: nil
        }
    }

    private func resolve(_ raw: String, cwd: String? = "/repo") -> TerminalLink {
        TerminalLink.resolve(raw, cwd: cwd, home: "/Users/me", fileKind: kind)
    }

    @Test func webAndOtherSchemes() {
        #expect(resolve("http://localhost:3000/app") == .web(URL(string: "http://localhost:3000/app")!))
        #expect(resolve("https://example.com/a).") == .web(URL(string: "https://example.com/a")!))
        #expect(resolve("mailto:me@example.com") == .other(URL(string: "mailto:me@example.com")!))
        #expect(resolve("file:///repo/README.md") == .file(path: "/repo/README.md", line: nil))
    }

    @Test func pathsResolveAgainstTheWorkingDirectoryAndHome() {
        #expect(resolve("./README.md") == .file(path: "/repo/README.md", line: nil))
        #expect(resolve("src/main.swift:42:7") == .file(path: "/repo/src/main.swift", line: 42))
        #expect(resolve("README.md:12") == .file(path: "/repo/README.md", line: 12))
        #expect(resolve("README.md") == .file(path: "/repo/README.md", line: nil))
        #expect(resolve("../repo/src") == .directory(path: "/repo/src"))
        #expect(resolve("~/notes.md") == .file(path: "/Users/me/notes.md", line: nil))
        #expect(resolve("/repo/my%20file.md") == .file(path: "/repo/my file.md", line: nil))
        #expect(resolve("/repo/src/main.swift:9") == .file(path: "/repo/src/main.swift", line: 9))
    }

    @Test func missingOrUnresolvable() {
        #expect(resolve("./gone.md") == .none)
        #expect(resolve("README.md", cwd: nil) == .none)
        #expect(resolve("   ") == .none)
    }

    @Test func workingDirectoryFromOSC7() {
        #expect(TerminalLink.workingDirectory(fromReported: "file://mac.local/Users/me/My%20Code") == "/Users/me/My Code")
        #expect(TerminalLink.workingDirectory(fromReported: "/tmp") == "/tmp")
        #expect(TerminalLink.workingDirectory(fromReported: "nonsense") == nil)
    }
}
