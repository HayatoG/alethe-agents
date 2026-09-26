import AletheDesign
import SwiftUI

/// The toolbar's `remote` item (upstream TitleBar remote pill): shown only while remote control is on,
/// with the connected device count (or "Remote control on" when none); opens the pairing sheet.
struct RemoteToolbarItem: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    private var remote: RemoteControlController { environment.remoteControl }

    var body: some View {
        if remote.isEnabled {
            let count = remote.info?.connectedDevices ?? 0
            let token: ThemeToken = count > 0 ? .statusActive : .textSecondary
            Button {
                environment.editorRequest = .remotePairing
            } label: {
                HStack(spacing: metrics.space(.xs)) {
                    Image(systemName: "iphone")
                    Text(Self.label(count))
                }
                .font(metrics.font(.caption).monospacedDigit())
                .padding(.horizontal, metrics.space(.s))
                .padding(.vertical, metrics.space(.xxs))
                .background(count > 0 ? theme[.statusActive].opacity(0.18) : theme[.bgSunken], in: Capsule())
                .foregroundStyle(theme[token])
            }
            .buttonStyle(.plain)
            .help(Text(Self.label(count)))
            .accessibilityIdentifier("remote.toolbarPill")
            // Devices connect and leave on their own; upstream polls every 2 s while on.
            .task {
                while !Task.isCancelled {
                    remote.refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    static func label(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "remote.pill.idle")
        case 1: String(localized: "remote.pill.oneDevice")
        default: String(format: String(localized: "remote.pill.devices"), count)
        }
    }
}
