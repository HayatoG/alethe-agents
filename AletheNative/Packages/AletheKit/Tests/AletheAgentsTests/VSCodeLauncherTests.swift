import Foundation
import Testing
@testable import AletheAgents

/// Open in VS Code resolution (P5-7).
struct VSCodeLauncherTests {
    private func resolver(_ files: Set<String>, path: String = "/usr/bin:/bin") -> LauncherResolver {
        LauncherResolver(environment: ["PATH": path], homeDirectory: "/Users/me",
                         isExecutable: { files.contains($0) }, listDirectory: { _ in [] })
    }

    @Test func theCLIWinsWhenTheResolverFindsIt() {
        let resolver = resolver(["/opt/homebrew/bin/code"])
        let resolution = VSCodeLauncher.resolve(resolver: { resolver.resolve($0) },
                                                appURL: { _ in URL(filePath: "/Applications/Visual Studio Code.app") })
        #expect(resolution == .cli("/opt/homebrew/bin/code"))
    }

    @Test func fallsBackToTheAppByBundleID() {
        let resolver = resolver([])
        let resolution = VSCodeLauncher.resolve(resolver: { resolver.resolve($0) }, appURL: { id in
            id == "com.microsoft.VSCode" ? URL(filePath: "/Applications/Visual Studio Code.app") : nil
        })
        #expect(resolution == .app(URL(filePath: "/Applications/Visual Studio Code.app")))
    }

    @Test func prefersStableOverInsidersOverVSCodium() {
        var asked: [String] = []
        let resolution = VSCodeLauncher.resolve(resolver: { _ in nil }, appURL: { id in
            asked.append(id)
            return id == "com.vscodium" ? URL(filePath: "/Applications/VSCodium.app") : nil
        })
        #expect(asked == VSCodeLauncher.bundleIdentifiers)
        #expect(resolution == .app(URL(filePath: "/Applications/VSCodium.app")))
    }

    @Test func missingWhenNeitherIsInstalled() {
        #expect(VSCodeLauncher.resolve(resolver: { _ in nil }, appURL: { _ in nil }) == .missing)
    }

    @Test func argumentsTakeAbsolutePathsOnly() {
        #expect(VSCodeLauncher.arguments(opening: "/work/app") == ["/work/app"])
        #expect(VSCodeLauncher.arguments(opening: "--install-extension=x") == nil)
        #expect(VSCodeLauncher.arguments(opening: "relative") == nil)
    }
}
