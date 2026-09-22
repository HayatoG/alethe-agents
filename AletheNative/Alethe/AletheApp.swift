import AletheDesign
import AletheFoundation
import SwiftUI

@main
struct AletheApp: App {
    init() {
        AletheFonts.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup(AppIdentity.productName) {
            RootView()
        }
    }
}

private struct RootView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        theme[.bg]
            .ignoresSafeArea()
            .frame(minWidth: 800, minHeight: 500)
    }
}
