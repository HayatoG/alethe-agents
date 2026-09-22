import AletheFoundation
import SwiftUI

@main
struct AletheApp: App {
    var body: some Scene {
        WindowGroup(AppIdentity.productName) {
            Color.clear
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
