import SwiftUI

/// Settings › Remote (upstream `RemoteControlPage`). A P7-6 slot, filled by P7-18.
struct RemoteSettings: View {
    var body: some View {
        Form {}
            .formStyle(.grouped)
            .accessibilityIdentifier("settings.remote")
    }
}
