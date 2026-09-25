import AletheDesign
import AlethePluginKit
import Foundation
import Testing
@testable import AletheThemePack

@Suite struct ThemePackTests {
    @Test(arguments: ThemePack.themeIDs)
    func themeDecodesWithEveryBuiltinToken(id: String) throws {
        let contribution = try #require(try ThemePack.contributions().first { $0.id == id })
        let theme = try JSONDecoder().decode(Theme.self, from: contribution.data)
        #expect(theme.id == id)
        #expect(theme.validationErrors.isEmpty, "\(id): \(theme.validationErrors)")
        let builtinTokens = Set(ThemeCatalog.builtin.themes.flatMap { $0.colors.keys })
        #expect(Set(theme.colors.keys) == builtinTokens)
        #expect(!theme.isLight)
    }

    @Test func contributionsCarryUpstreamNames() throws {
        let names = try ThemePack.contributions().map(\.name)
        #expect(names == ["Dark Lemon", "Orca", "Ember", "Golden Premium"])
    }

    @MainActor
    @Test func pluginContributesFourUniqueThemesAvoidingBuiltins() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "theme-pack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = PluginHost(plugins: [ThemePackPlugin.self], dataRoot: root)
        await host.load()

        #expect(host.record(for: ThemePackPlugin.manifest.id)?.state == .active)
        let ids = host.contributions.themes.map(\.id)
        #expect(ids.count == 4)
        #expect(Set(ids).count == 4)
        #expect(Set(ids).isDisjoint(with: ThemeCatalog.builtinOrder))
        #expect(host.contributions.sidebarTabs.isEmpty && host.contributions.commands.isEmpty)
    }

    @Test func mergedCatalogListsBuiltinsThenPack() throws {
        let merged = ThemeCatalog.builtin.merging(contributions: try ThemePack.contributions())
        #expect(merged.themes.map(\.id) == ThemeCatalog.builtinOrder + ThemePack.themeIDs)
        #expect(merged.resolved(id: "ember").id == "ember")
    }

    @Test func mergeDropsCollidingAndInvalidContributions() throws {
        let pack = try ThemePack.contributions()
        let dark = try #require(ThemeCatalog.builtin.theme(id: "dark"))
        let colliding = ThemeContribution(id: "dark", name: "Fake Dark", data: try JSONEncoder().encode(dark))
        let broken = ThemeContribution(id: "broken", name: "Broken", data: Data("{}".utf8))
        let merged = ThemeCatalog.builtin.merging(contributions: pack + [colliding, broken] + pack)
        #expect(merged.themes.count == ThemeCatalog.builtinOrder.count + 4)
        #expect(merged.theme(id: "broken") == nil)
    }
}
