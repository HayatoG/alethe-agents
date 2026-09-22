import AletheDesign
import AletheFoundation
import SwiftUI

@main
struct AletheApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var environment = AppEnvironment()

    init() {
        AletheFonts.registerBundledFonts()
    }

    var body: some Scene {
        // A single main window: ⌘N belongs to "New Project", not to a second workspace window.
        Window(AppIdentity.productName, id: "main") {
            MainWindow()
                .environment(environment)
                .environment(\.theme, environment.theme)
                .environment(\.metrics, environment.metrics)
                .preferredColorScheme(environment.theme.isLight ? .light : .dark)
                .task {
                    delegate.environment = environment
                    await environment.load()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ViewCommands(environment: environment)
        }

        Settings {
            SettingsView()
                .environment(environment)
                .environment(\.theme, environment.theme)
                .environment(\.metrics, environment.metrics)
        }
    }
}

/// View menu additions: UI zoom. Font and metric scale only — never `scaleEffect` (plan lesson 1).
private struct ViewCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("menu.view.zoomIn") { environment.preferences?.update { $0.zoom(by: 1) } }
                .keyboardShortcut("+", modifiers: .command)
            Button("menu.view.zoomOut") { environment.preferences?.update { $0.zoom(by: -1) } }
                .keyboardShortcut("-", modifiers: .command)
            Button("menu.view.actualSize") { environment.preferences?.update { $0.uiScale = 1 } }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}
