import AletheDesign
import AletheFoundation
import AletheTerminal
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
        TerminalPane(launch: TerminalSpike.launch(), theme: theme)
            .frame(minWidth: 800, minHeight: 500)
            .background(theme[.bg])
    }
}

/// Hosts one `TerminalPaneView`. The pane is created once and kept: SwiftUI must never recreate
/// the terminal's Metal surface (ADR-3).
private struct TerminalPane: NSViewRepresentable {
    let launch: PTYLaunch
    let theme: Theme

    func makeNSView(context: Context) -> NSView {
        do {
            let pane = try TerminalPaneView(launch: launch, theme: theme)
            TerminalSpike.attach(pane)
            DispatchQueue.main.async { pane.focus() }
            return pane
        } catch {
            return NSView()
        }
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? TerminalPaneView)?.applyTheme(theme)
    }
}
