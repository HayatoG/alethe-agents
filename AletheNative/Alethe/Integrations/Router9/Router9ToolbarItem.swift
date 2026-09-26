import AletheDesign
import SwiftUI

/// The toolbar's `router9` item (upstream `Router9PillButton`): shown while 9router is enabled and
/// installed; the status dot and a click that starts or stops it.
struct Router9ToolbarItem: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    private var controller: Router9Controller { environment.router9 }

    var body: some View {
        Group {
            if controller.preferences.enabled {
                if controller.hasInstall { pill }
                else { Color.clear.frame(width: 0, height: 0).accessibilityHidden(true) }
            }
        }
        // Probes only while the item is on screen and 9router is on.
        .task(id: controller.preferences.enabled) {
            if controller.preferences.enabled { await controller.watch() }
        }
    }

    private var pill: some View {
        let running = controller.isRunning
        return Button {
            Task { await controller.toggleRunning() }
        } label: {
            Label {
                Text(running ? "router9.pill.running" : "router9.pill.stopped")
            } icon: {
                Image(systemName: "circle.fill")
                    .font(.system(size: metrics.size(7)))
                    .foregroundStyle(theme[running ? .statusActive : .statusDisabled])
            }
            .labelStyle(.titleAndIcon)
        }
        .disabled(controller.busy)
        .help(Text(running ? "router9.pill.stop" : "router9.pill.start"))
        .accessibilityValue(Text(running ? "router9.pill.on" : "router9.pill.off"))
        .accessibilityIdentifier("toolbar.router9")
    }
}
