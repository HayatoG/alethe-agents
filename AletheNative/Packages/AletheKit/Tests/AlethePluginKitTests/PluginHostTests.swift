import Foundation
import Testing
@testable import AletheFoundation
@testable import AlethePluginKit

private struct Boom: Error {}

private final class TabsPlugin: AlethePlugin {
    static let manifest = PluginManifest(id: "test.tabs", version: "1.0.0", name: "Tabs", capabilities: [.storage])
    func activate(context: PluginContext) throws {
        try context.addSidebarTab(SidebarTabContribution(id: "tabs.main", title: "Tabs", symbol: "list.bullet", side: .right, viewID: "tabs.view"))
        try context.addCommand(CommandContribution(id: "tabs.open", title: "Open Tabs") {})
        try context.addSettingsPage(SettingsPageContribution(id: "tabs.settings", title: "Tabs", symbol: "gear", viewID: "tabs.settings.view"))
    }
}

private final class ThemesPlugin: AlethePlugin {
    static let manifest = PluginManifest(id: "test.themes", version: "0.1.0", name: "Themes", enabledByDefault: false)
    func activate(context: PluginContext) throws {
        try context.addTheme(ThemeContribution(id: "themes.dusk", name: "Dusk", data: Data("{}".utf8)))
    }
}

/// Registers a contribution, then throws: nothing it registered may survive.
private final class FailingPlugin: AlethePlugin {
    static let manifest = PluginManifest(id: "test.failing", version: "1.0.0", name: "Failing")
    func activate(context: PluginContext) throws {
        try context.addPaneKind(PaneKindContribution(id: "failing.pane", title: "Failing", symbol: "xmark", viewID: "failing.view"))
        throw Boom()
    }
}

/// Uses storage without declaring it.
private final class SneakyPlugin: AlethePlugin {
    static let manifest = PluginManifest(id: "test.sneaky", version: "1.0.0", name: "Sneaky")
    func activate(context: PluginContext) throws {
        _ = try context.storage()
    }
}

private final class FuturePlugin: AlethePlugin {
    static let manifest = PluginManifest(id: "test.future", version: "1.0.0", name: "Future", apiVersion: PluginAPIVersion(major: 2))
    func activate(context: PluginContext) throws {}
}

private final class DuplicateTabsPlugin: AlethePlugin {
    static let manifest = PluginManifest(id: "test.tabs", version: "2.0.0", name: "Tabs again")
    func activate(context: PluginContext) throws {}
}

private final class BadIDPlugin: AlethePlugin {
    static let manifest = PluginManifest(id: "../escape", version: "1.0.0", name: "Bad")
    func activate(context: PluginContext) throws {}
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "alethe-plugin-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@MainActor
@Suite struct PluginHostTests {
    @Test func activatesEnabledPluginsAndCollectsContributions() async {
        let host = PluginHost(plugins: [TabsPlugin.self, ThemesPlugin.self], dataRoot: temporaryDirectory())
        await host.load()
        #expect(host.record(for: "test.tabs")?.state == .active)
        #expect(host.record(for: "test.themes")?.state == .disabled)
        #expect(host.contributions.sidebarTabs.map(\.side) == [.right])
        #expect(host.contributions.commands.map(\.id) == ["tabs.open"])
        #expect(host.contributions.settingsPages.count == 1)
        #expect(host.contributions.themes.isEmpty)
    }

    @Test func viewPlacementSurvivesANewHost() async throws {
        let root = temporaryDirectory()
        let first = PluginHost(plugins: [TabsPlugin.self], dataRoot: root)
        await first.load()
        try await first.moveSidebarTab("tabs.main", to: .left, at: 0)
        #expect(first.viewPlacements.arranged(first.contributions.sidebarTabs).left.map(\.id) == ["tabs.main"])
        let second = PluginHost(plugins: [TabsPlugin.self], dataRoot: root)
        await second.load()
        #expect(second.viewPlacements.side(of: "tabs.main", in: second.contributions.sidebarTabs) == .left)
        try await second.resetViewPlacements()
        #expect(second.viewPlacements == .empty)
    }

    @Test func enabledStateSurvivesANewHost() async throws {
        let root = temporaryDirectory()
        let first = PluginHost(plugins: [TabsPlugin.self, ThemesPlugin.self], dataRoot: root)
        await first.load()
        try await first.setEnabled(false, for: "test.tabs")
        try await first.setEnabled(true, for: "test.themes")
        #expect(first.contributions.sidebarTabs.isEmpty)
        #expect(first.contributions.themes.map(\.id) == ["themes.dusk"])

        let relaunched = PluginHost(plugins: [TabsPlugin.self, ThemesPlugin.self], dataRoot: root)
        await relaunched.load()
        #expect(relaunched.record(for: "test.tabs")?.isEnabled == false)
        #expect(relaunched.record(for: "test.tabs")?.state == .disabled)
        #expect(relaunched.record(for: "test.themes")?.state == .active)
        #expect(relaunched.contributions.themes.map(\.id) == ["themes.dusk"])
        #expect(relaunched.contributions.sidebarTabs.isEmpty)
    }

    @Test func failingPluginIsIsolated() async throws {
        let host = PluginHost(plugins: [FailingPlugin.self, TabsPlugin.self, SneakyPlugin.self], dataRoot: temporaryDirectory())
        await host.load()
        guard case .failed(let message) = host.record(for: "test.failing")?.state else {
            Issue.record("not failed"); return
        }
        #expect(message.contains("Boom"))
        #expect(host.contributions.paneKinds.isEmpty)
        #expect(host.contributions(of: "test.failing") == nil)
        #expect(host.record(for: "test.tabs")?.state == .active)
        #expect(host.contributions.sidebarTabs.count == 1)
        guard case .failed(let sneaky) = host.record(for: "test.sneaky")?.state else {
            Issue.record("sneaky not failed"); return
        }
        #expect(sneaky.contains("undeclaredCapability"))
        // Disabling and re-enabling retries it; it fails the same way without affecting others.
        try await host.setEnabled(false, for: "test.failing")
        #expect(host.record(for: "test.failing")?.state == .disabled)
        try await host.setEnabled(true, for: "test.failing")
        #expect(host.record(for: "test.failing")?.state != .active)
        #expect(host.record(for: "test.tabs")?.state == .active)
    }

    @Test func invalidManifestsNeverActivate() async {
        let host = PluginHost(
            plugins: [TabsPlugin.self, DuplicateTabsPlugin.self, FuturePlugin.self, BadIDPlugin.self],
            dataRoot: temporaryDirectory()
        )
        await host.load()
        #expect(host.records.map(\.state) == [
            .active,
            .failed(String(describing: PluginError.duplicatePlugin("test.tabs"))),
            .failed(String(describing: PluginError.incompatibleAPI(required: PluginAPIVersion(major: 2), host: .current))),
            .failed(String(describing: PluginError.invalidID("../escape"))),
        ])
    }

    @Test func unknownPluginCannotBeToggled() async {
        let host = PluginHost(plugins: [TabsPlugin.self], dataRoot: temporaryDirectory())
        await host.load()
        await #expect(throws: PluginError.unknownPlugin("nope")) { try await host.setEnabled(true, for: "nope") }
    }

    @Test func apiVersionCompatibility() {
        #expect(PluginAPIVersion(major: 1, minor: 0).isCompatible(withHost: PluginAPIVersion(major: 1, minor: 2)))
        #expect(!PluginAPIVersion(major: 1, minor: 3).isCompatible(withHost: PluginAPIVersion(major: 1, minor: 2)))
        #expect(!PluginAPIVersion(major: 0, minor: 9).isCompatible(withHost: PluginAPIVersion(major: 1, minor: 0)))
    }
}
