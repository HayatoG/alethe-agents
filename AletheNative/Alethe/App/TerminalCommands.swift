import AletheModel
import AletheTerminal
import SwiftUI

/// Terminal menu: actions on the focused pane's visible terminal.
struct TerminalCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandMenu("menu.terminal") {
            Button("menu.terminal.previousPrompt") { focusedTerminal?.jumpToPrompt(-1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(focusedTerminal == nil)
            Button("menu.terminal.nextPrompt") { focusedTerminal?.jumpToPrompt(1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(focusedTerminal == nil)
        }
    }

    @MainActor private var focusedTerminal: TerminalPaneView? {
        environment.focusedTerminal
    }
}

extension AppEnvironment {
    /// The terminal of the focused pane's active tab, when it is running.
    var focusedTerminal: TerminalPaneView? {
        guard let document = workspace?.document, let pane = document.workspace.focusedPaneID,
              let tab = document.pane(pane)?.pane.activeTab else { return nil }
        return terminals.view(for: tab.id)
    }
}
