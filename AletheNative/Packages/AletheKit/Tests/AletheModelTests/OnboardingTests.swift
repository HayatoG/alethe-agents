import Foundation
import Testing
@testable import AletheModel

struct OnboardingTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func stepsSkipImportWithoutTauriDataAndMcpWhenOff() {
        #expect(OnboardingStep.steps(tauriDataAvailable: false, mcpEnabled: false)
                == [.name, .appearance, .agents, .features])
        #expect(OnboardingStep.steps(tauriDataAvailable: true, mcpEnabled: true)
                == [.name, .importData, .appearance, .agents, .features, .mcp])
    }

    @Test func firstLaunchOnboardsUntilDoneThenStaysQuiet() {
        var preferences = PreferencesDocument()
        #expect(preferences.recordLaunch(version: "1.0", hasProjects: false, now: start) == .onboarding)
        #expect(preferences.firstLaunchAt == start)
        // Not finished: asked again next launch.
        #expect(preferences.recordLaunch(version: "1.0", hasProjects: false, now: start + 60) == .onboarding)
        preferences.onboardingDone = true
        #expect(preferences.recordLaunch(version: "1.0", hasProjects: false, now: start + 120) == .none)
        #expect(preferences.firstLaunchAt == start)
        #expect(preferences.lastLaunchAt == start + 120)
    }

    @Test func existingWorkspaceSkipsOnboarding() {
        var preferences = PreferencesDocument()
        #expect(preferences.recordLaunch(version: "1.0", hasProjects: true, now: start) == .none)
        #expect(preferences.onboardingDone == true)
    }

    @Test func welcomeBackAfterUpdateOrLongAbsence() {
        var preferences = PreferencesDocument()
        preferences.onboardingDone = true
        // Upgrading into this feature: no previous launch recorded, no greeting.
        #expect(preferences.recordLaunch(version: "1.0", hasProjects: true, now: start) == .none)

        let day2 = start + 86_400 + 10
        #expect(preferences.recordLaunch(version: "1.1", hasProjects: true, now: day2)
                == .welcomeBack(WelcomeBack(day: 2, updatedFrom: "1.0")))
        #expect(preferences.lastSeenVersion == "1.1")
        #expect(preferences.recordLaunch(version: "1.1", hasProjects: true, now: day2 + 3600) == .none)

        let later = day2 + 3600 + WelcomeBack.absence + 86_400
        #expect(preferences.recordLaunch(version: "1.1", hasProjects: true, now: later)
                == .welcomeBack(WelcomeBack(day: WelcomeBack.day(since: start, now: later), absentDays: 8)))
    }

    @Test func dayCountStartsAtOne() {
        #expect(WelcomeBack.day(since: nil, now: start) == 1)
        #expect(WelcomeBack.day(since: start, now: start + 10) == 1)
        #expect(WelcomeBack.day(since: start, now: start + 86_400 * 3) == 4)
        #expect(WelcomeBack.day(since: start + 50, now: start) == 1)
    }

    @Test func suggestedNameIsTheFirstName() {
        #expect(OnboardingName.suggested(fullName: "Ada Lovelace", userName: "ada") == "Ada")
        #expect(OnboardingName.suggested(fullName: "  ", userName: "ada") == "ada")
    }

    @Test func decodesWithoutTheNewKeys() throws {
        let json = #"{"schemaVersion":2,"themeID":"elite-indigo","uiScale":1,"alwaysStartUnrestricted":false}"#
        let decoded = try JSONDecoder().decode(PreferencesDocument.self, from: Data(json.utf8))
        #expect(decoded.onboardingDone == nil && decoded.firstLaunchAt == nil && decoded.lastSeenVersion == nil)
    }
}
