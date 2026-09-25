import SwiftUI

/// Containing app of the sample extension: ExtensionKit extensions ship inside an app
/// (`Contents/Extensions`). Launching it once registers the extension with the system.
@main
struct AletheSampleApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("sample.app.title").font(.headline)
                Text("sample.app.message").foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 420)
        }
        .windowResizability(.contentSize)
    }
}
