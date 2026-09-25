import Foundation
import Testing
@testable import AletheFoundation

@Suite struct CLIShimTests {
    private let app = "/Applications/Alethe.app"

    @Test func scriptIsAPosixScriptThatOpensTheBundle() throws {
        let script = try #require(CLIShim.script(appPath: app))
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("target=${1:-.}"))
        #expect(script.contains("exec /usr/bin/open -a '/Applications/Alethe.app' \"$target\""))
        #expect(script.contains("pwd -P"))
    }

    @Test func scriptRecordsTheTargetAppAndVersion() throws {
        let script = try #require(CLIShim.script(appPath: app))
        #expect(CLIShim.targetApp(in: script) == app)
        #expect(CLIShim.value(of: CLIShim.versionMarker, in: script) == String(CLIShim.version))
    }

    @Test func singleQuotesInThePathAreEscaped() throws {
        let script = try #require(CLIShim.script(appPath: "/Users/o'neil/Apps/Alethe.app"))
        #expect(script.contains(#"'/Users/o'\''neil/Apps/Alethe.app'"#))
        #expect(CLIShim.targetApp(in: script) == "/Users/o'neil/Apps/Alethe.app")
    }

    @Test func quoteWrapsShellMetacharacters() {
        #expect(CLIShim.quote("plain") == "'plain'")
        #expect(CLIShim.quote("a b$c`d\"e") == "'a b$c`d\"e'")
        #expect(CLIShim.quote("it's") == #"'it'\''s'"#)
        #expect(CLIShim.quote("") == "''")
    }

    @Test func pathsACommentCannotHoldAreRefused() {
        #expect(CLIShim.script(appPath: "/Apps/Ale\nthe.app") == nil)
        #expect(CLIShim.script(appPath: "") == nil)
    }

    @Test(arguments: ["/Applications/Alethe.app", "/Users/me/Apps/Alethe Beta.app", "/tmp/o'neil/Alethe.app",
                      "/tmp/$HOME/`x`/Alethe.app"])
    func generatedScriptIsValidShellSyntax(_ path: String) throws {
        let script = try #require(CLIShim.script(appPath: path))
        let file = FileManager.default.temporaryDirectory.appending(path: "alethe-shim-\(UUID().uuidString).sh")
        try Data(script.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-n", file.path]
        try shell.run()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)
    }

    @Test func stateComparesTheTargetAndVersion() throws {
        let script = try #require(CLIShim.script(appPath: app))
        #expect(CLIShim.state(of: nil, appPath: app) == .missing)
        #expect(CLIShim.state(of: script, appPath: app) == .current)
        #expect(CLIShim.state(of: script, appPath: "/Users/me/Applications/Alethe.app") == .stale)
        let older = script.replacingOccurrences(of: "\(CLIShim.versionMarker) \(CLIShim.version)",
                                                with: "\(CLIShim.versionMarker) 0")
        #expect(CLIShim.state(of: older, appPath: app) == .stale)
        #expect(CLIShim.state(of: "#!/bin/sh\necho hi\n", appPath: app) == .foreign)
    }

    @Test func upstreamShimsWithTheOldMarkerAreForeign() {
        let tauri = "#!/bin/sh\n# ALETHE_TARGET_BIN: /Applications/Alethe.app\nexec open -na x\n"
        #expect(CLIShim.state(of: tauri, appPath: app) == .foreign)
    }

    @Test func installWritesAnExecutableAndUninstallRemovesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "alethe-shim-\(UUID().uuidString)/bin")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let file = try CLIShim.install(appPath: app, in: directory)
        #expect(file.lastPathComponent == "alethe")
        #expect(FileManager.default.isExecutableFile(atPath: file.path))
        #expect(CLIShim.state(of: CLIShim.read(in: directory), appPath: app) == .current)
        try CLIShim.uninstall(in: directory)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try CLIShim.uninstall(in: directory)
    }

    @Test func uninstallLeavesAForeignFileAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "alethe-shim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = CLIShim.location(in: directory)
        try Data("#!/bin/sh\necho mine\n".utf8).write(to: file)
        #expect(throws: (any Error).self) { try CLIShim.uninstall(in: directory) }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func pathContainsMatchesEntriesLoosely() {
        let bin = URL(filePath: "/Users/me/.local/bin")
        #expect(CLIShim.pathContains(bin, pathVariable: "/usr/bin:/Users/me/.local/bin:/bin"))
        #expect(CLIShim.pathContains(bin, pathVariable: "/usr/bin:/Users/me/.local/bin/"))
        #expect(!CLIShim.pathContains(bin, pathVariable: "/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(!CLIShim.pathContains(bin, pathVariable: ""))
    }

    @Test func pathProbeOutputIgnoresProfileNoise() {
        let output = "Welcome!\nlast login\n\n__ALETHE_PATH__=/opt/homebrew/bin:/usr/bin\n"
        #expect(CLIShim.parsePathProbe(output) == "/opt/homebrew/bin:/usr/bin")
        #expect(CLIShim.parsePathProbe("nothing here") == nil)
    }

    @Test func defaultDirectoryIsLocalBin() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        #expect(CLIShim.defaultDirectory(home: home).path == "/Users/me/.local/bin")
    }
}
