import Foundation
import Testing
@testable import AletheFoundation

@Suite struct AppLanguageTests {
    /// A throwaway defaults domain standing in for the app's own.
    private func withDomain(_ body: (UserDefaults, LanguageSetting) -> Void) {
        let domain = "com.kc1t.alethe.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        body(defaults, LanguageSetting(domain: domain))
    }

    @Test func storesTheChoiceAsTheAppsOwnLanguageList() {
        withDomain { defaults, setting in
            #expect(setting.current(in: defaults) == .system)
            setting.set(.portugueseBrazil, in: defaults)
            #expect(defaults.persistentDomain(forName: setting.domain)?["AppleLanguages"] as? [String] == ["pt-BR"])
            #expect(setting.current(in: defaults) == .portugueseBrazil)
            setting.set(.system, in: defaults)
            #expect(defaults.persistentDomain(forName: setting.domain)?["AppleLanguages"] == nil)
            #expect(setting.current(in: defaults) == .system)
        }
    }

    /// What System Settings › Language & Region › Applications writes is read back too.
    @Test func readsRegionalVariantsAndUnknownLanguages() {
        withDomain { defaults, setting in
            defaults.setPersistentDomain(["AppleLanguages": ["en-GB"]], forName: setting.domain)
            #expect(setting.current(in: defaults) == .english)
            defaults.setPersistentDomain(["AppleLanguages": ["fr"]], forName: setting.domain)
            #expect(setting.current(in: defaults) == .system)
        }
    }

    @Test func relaunchDropsLanguageOverridesOnly() {
        let arguments = ["-AletheDataRoot", "/tmp/x", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-Other", "1"]
        #expect(LanguageSetting.relaunchArguments(arguments) == ["-AletheDataRoot", "/tmp/x", "-Other", "1"])
        #expect(LanguageSetting.relaunchArguments([]) == [])
    }
}
