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
            FileCommands(environment: environment)
            ViewCommands(environment: environment)
            TerminalCommands(environment: environment)
        }

        Settings {
            SettingsView()
                .environment(environment)
                .environment(\.theme, environment.theme)
                .environment(\.metrics, environment.metrics)
                .preferredColorScheme(environment.theme.isLight ? .light : .dark)
        }
    }
}

/// File menu: adding projects and groups (undoable through the key window's undo manager).
private struct FileCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("menu.file.newProject") { environment.editorRequest = .newProject(.ungrouped) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(environment.workspace == nil)
            Button("menu.file.newGroup") { environment.editorRequest = .newGroup(parent: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(environment.workspace == nil)
            Button("menu.file.newTerminal") { environment.editorRequest = .newTerminal(nil) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(environment.workspace?.document.projects.isEmpty ?? true)
            Button("menu.file.addContent") { environment.editorRequest = .addContent(nil) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(AddContentSheet.options.isEmpty || (environment.workspace?.document.projects.isEmpty ?? true))
            Divider()
            Button("sidebar.addProject") { actions?.chooseFolders() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(environment.workspace == nil)
            Button("menu.file.importTauri") { environment.editorRequest = .importTauri }
                .disabled(environment.workspace == nil)
        }
    }

    @MainActor private var actions: SidebarActions? {
        environment.workspace.map { SidebarActions(workspace: $0, undoManager: NSApp.keyWindow?.undoManager) }
    }
}

/// View menu additions: UI zoom (font and metric scale only — never `scaleEffect`, plan lesson 1),
/// and showing one pane or one project alone.
private struct ViewCommands: Commands {
    let environment: AppEnvironment

    @MainActor private var isolated: Bool { environment.workspace?.document.workspace.isolatedPaneID != nil }
    @MainActor private var fullscreen: Bool { environment.workspace?.document.workspace.fullscreenProjectID != nil }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("menu.view.zoomIn") { environment.preferences?.update { $0.zoom(by: 1) } }
                .keyboardShortcut("+", modifiers: .command)
            Button("menu.view.zoomOut") { environment.preferences?.update { $0.zoom(by: -1) } }
                .keyboardShortcut("-", modifiers: .command)
            Button("menu.view.actualSize") { environment.preferences?.update { $0.uiScale = 1 } }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button(isolated ? LocalizedStringKey("menu.view.showAllPanes") : "menu.view.showPaneAlone") {
                environment.workspace?.update { $0.isolate(isolated ? nil : $0.workspace.focusedPaneID) }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(environment.workspace?.document.workspace.focusedPaneID == nil && !isolated)
            Button(fullscreen ? LocalizedStringKey("menu.view.showAllProjects") : "menu.view.showProjectAlone") {
                environment.workspace?.update { $0.setFullscreen(fullscreen ? nil : $0.workspace.selectedProjectID) }
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(environment.workspace?.document.workspace.selectedProjectID == nil && !fullscreen)
            Divider()
        }
    }
}
