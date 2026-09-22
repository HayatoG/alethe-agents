import Foundation
import Testing
@testable import AletheFoundation

@Suite struct AppIdentityTests {
    @Test func bundleIdentifierDiffersFromTauriApp() {
        #expect(AppIdentity.bundleIdentifier == "com.kc1t.alethe.mac")
        #expect(AppIdentity.bundleIdentifier != "com.kc1t.alethe")
    }

    @Test func applicationSupportDirectoryIsScopedByBundleIdentifier() throws {
        let url = try AppIdentity.applicationSupportDirectory()
        #expect(url.lastPathComponent == AppIdentity.bundleIdentifier)
        #expect(url.pathComponents.contains("Application Support"))
    }
}
