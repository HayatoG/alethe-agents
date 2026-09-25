import Testing
@testable import AletheAgents

/// Agent CLI install catalog (P3-3; upstream `agentInstall.test.ts`, `agentVersions.ts`).
@Suite struct AgentInstallTests {
    private let everything = InstallToolchain(node: "22.1.0", npm: true, brew: true)

    @Test func everyAgentWithACLIHasAnEntry() {
        for descriptor in AgentRegistry.builtin.descriptors where !descriptor.isShell {
            #expect(AgentInstallCatalog.entries[descriptor.kind] != nil, "\(descriptor.displayName) has install methods")
        }
    }

    @Test func methodsFollowTheToolchainAndPreferScripts() {
        #expect(AgentInstallCatalog.methods(for: .claude, toolchain: everything).map(\.kind) == [.native, .brew, .npm])
        #expect(AgentInstallCatalog.methods(for: .claude, toolchain: InstallToolchain()).map(\.kind) == [.native])
        #expect(AgentInstallCatalog.methods(for: .copilot, toolchain: nil).isEmpty, "unknown toolchain: nothing that needs one")
    }

    @Test func uninstallIsDerivedForPackageManagersOnly() {
        let removals = AgentInstallCatalog.uninstallMethods(for: .opencode, toolchain: everything)
        #expect(removals.map(\.command) == ["brew uninstall anomalyco/tap/opencode", "npm uninstall -g opencode-ai"])
        let allVerifyAbsence = removals.allSatisfy { $0.verifyAbsent }
        #expect(allVerifyAbsence)
        #expect(AgentInstallCatalog.uninstallMethods(for: .cursor, toolchain: everything).isEmpty, "script installs are not guessed")
        #expect(AgentInstallCatalog.uninstallMethods(for: .copilot, toolchain: everything).first?.command
                == "brew uninstall --cask copilot-cli")
    }

    @Test func nodeIsNeededOnlyWhenNpmIsTheOnlyWay() {
        let bare = InstallToolchain()
        #expect(AgentInstallCatalog.needsNode(.freebuff, toolchain: bare))
        #expect(!AgentInstallCatalog.needsNode(.claude, toolchain: bare), "it has an install script")
        #expect(AgentInstallCatalog.nodeMethods(toolchain: InstallToolchain(brew: true)).first?.command == "brew install node")
        #expect(AgentInstallCatalog.nodeMethods(toolchain: bare).isEmpty)
    }

    @Test func npmPackagesAndVersions() {
        #expect(AgentInstallCatalog.npmPackage(for: .codex) == "@openai/codex")
        #expect(AgentInstallCatalog.npmPackage(for: .kiro) == nil)
        #expect(AgentVersions.isOutdated("1.2.3", latest: "1.10.0"))
        #expect(!AgentVersions.isOutdated("v2.0.0", latest: "2.0.0-beta.1"))
        #expect(!AgentVersions.isOutdated("2.0.1", latest: "2.0"))
    }

    @Test func logsLoseEscapesAndKeepTheirTail() {
        #expect(InstallLog.clean("\u{1B}[32madded\u{1B}[0m 3 packages\r\n") == "added 3 packages\n")
        let long = String(repeating: "x", count: InstallLog.maxCharacters + 10)
        #expect(InstallLog.clean(long).count == InstallLog.maxCharacters)
    }
}
