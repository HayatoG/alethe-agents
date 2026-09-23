import AletheAgents
import AletheDesign
import AletheModel
import AletheTerminal
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One tab's terminal, with the overlays for a process that ended or could not start.
struct TerminalHost: View {
    let tab: PaneTab
    let project: Project
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        let terminals = environment.terminals
        ZStack {
            theme[.bg]
            TerminalViewSlot(view: terminals.view(for: tab.id), generation: terminals.generations[tab.id] ?? 0)
            switch terminals.states[tab.id] {
            case .exited(let code):
                overlay {
                    Text(verbatim: format("terminal.exited", Int(code)))
                        .foregroundStyle(theme[.textPrimary])
                    restartButton
                }
            case .notFound(let command):
                overlay {
                    Text(verbatim: format("terminal.notFound", AgentLabels.name(for: tab.agent), command))
                        .foregroundStyle(theme[.textPrimary])
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("terminal.chooseCLI") { chooseCLI(command: command) }
                        restartButton
                    }
                }
            case .failed(let message):
                overlay {
                    Text("terminal.failed").foregroundStyle(theme[.textPrimary])
                    Text(verbatim: message).font(metrics.font(.footnote)).foregroundStyle(theme[.textSecondary])
                    restartButton
                }
            case .running, nil:
                EmptyView()
            }
        }
        .task(id: tab.id) {
            terminals.ensureStarted(tab, in: project, environment: environment)
        }
    }

    private var restartButton: some View {
        Button("terminal.restart") { environment.terminals.restart(tab, in: project, environment: environment) }
            .keyboardShortcut(.defaultAction)
            .tint(theme[.accent])
            .accessibilityIdentifier("terminal.restart")
    }

    private func overlay(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: metrics.space(.m)) { content() }
            .font(metrics.font(.body))
            .padding(metrics.space(.xl))
            .background(theme[.bgElevated], in: RoundedRectangle(cornerRadius: metrics.radius(.lg)))
            .overlay(RoundedRectangle(cornerRadius: metrics.radius(.lg)).strokeBorder(theme[.border]))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("terminal.overlay")
    }

    /// Points the agent at a CLI the resolver missed (upstream `configurePath`).
    private func chooseCLI(command: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = format("terminal.chooseCLI.message", command)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let descriptor = AgentRegistry.builtin.descriptor(for: AgentKind(rawValue: tab.agent)),
              LauncherResolver.path(url.path, matches: descriptor) else {
            let alert = NSAlert()
            alert.messageText = String(localized: "terminal.cliMismatch")
            alert.informativeText = format("terminal.cliMismatch.detail", command)
            alert.runModal()
            return
        }
        environment.preferences?.update { preferences in
            var paths = preferences.cliPaths ?? [:]
            paths[tab.agent] = url.path
            preferences.cliPaths = paths
        }
        environment.terminals.restart(tab, in: project, environment: environment)
    }
}

/// A catalog string with `%1$@`-style placeholders filled in.
private func format(_ key: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
    String(format: String(localized: key), arguments: arguments)
}

/// Hosts a registry-owned terminal view; re-parents it when the tab or its process changes.
private struct TerminalViewSlot: NSViewRepresentable {
    let view: TerminalPaneView?
    let generation: Int

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        // A plain NSView is invisible to accessibility; the pane must be findable (VoiceOver, UI tests).
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel(String(localized: "terminal.accessibilityLabel"))
        container.setAccessibilityIdentifier("terminal.pane")
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard container.subviews.first !== view else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let view else { return }
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async { view.focus() }
    }
}
