import AletheAgents
import AletheDesign
import AletheModel
import AppKit
import SwiftUI

/// Settings › Agents (upstream Preferences › Terminal: enabled agents and CLI paths): each agent can
/// be turned off (it leaves New Terminal and the launcher) and shows the CLI it will run, with the
/// version it reports; Choose… points it at another CLI, Reset goes back to automatic lookup.
struct AgentSettings: View {
    @Environment(AppEnvironment.self) private var environment

    private var agents: [AgentDescriptor] { AgentRegistry.builtin.descriptors.filter { !$0.isShell } }

    var body: some View {
        Form {
            Section {
                ForEach(agents) { agent in
                    AgentSettingsRow(agent: agent)
                }
            } footer: {
                Text("settings.agents.footer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSettingsRow: View {
    let agent: AgentDescriptor
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @State private var version: String?
    @State private var probing = false

    private var preferences: PreferencesDocument? { environment.preferences?.document }
    private var override: String? { preferences?.cliPaths?[agent.kind.rawValue] }
    private var path: String? {
        agent.cliCommand.flatMap { environment.launchers.resolve($0, override: override) }
    }
    private var isEnabled: Bool {
        AgentRegistry.builtin.enabledKinds(preferences?.enabledAgents).contains(agent.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.space(.xs)) {
            Toggle(isOn: Binding(get: { isEnabled }, set: setEnabled)) {
                HStack(spacing: metrics.space(.s)) {
                    Circle()
                        .fill(theme[AgentTokens.accent(for: agent.kind.rawValue)])
                        .frame(width: metrics.size(8), height: metrics.size(8))
                    Text(verbatim: agent.displayName)
                    if let version {
                        Text(verbatim: version)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if probing {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .accessibilityIdentifier("settings.agent.\(agent.kind.rawValue)")
            HStack(spacing: metrics.space(.s)) {
                Text(verbatim: path ?? String(format: String(localized: "settings.agents.notFound"), agent.cliCommand ?? ""))
                    .font(.footnote.monospaced())
                    .foregroundStyle(path == nil ? theme[.statusStopped] : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                if override != nil {
                    Text("settings.agents.custom")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("settings.agents.reset") { setOverride(nil) }
                        .accessibilityIdentifier("settings.agent.reset.\(agent.kind.rawValue)")
                }
                Button("settings.agents.choose") { choose() }
                    .accessibilityIdentifier("settings.agent.choose.\(agent.kind.rawValue)")
            }
        }
        .task(id: path) { await probe() }
    }

    private func probe() async {
        version = nil
        guard let path else { return }
        probing = true
        version = await CLIVersion.probe(path)
        probing = false
    }

    private func setEnabled(_ enabled: Bool) {
        environment.preferences?.update {
            $0.enabledAgents = AgentRegistry.builtin.enabled($0.enabledAgents, setting: agent.kind, on: enabled)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = format("terminal.chooseCLI.message", agent.cliCommand ?? agent.displayName)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard LauncherResolver.path(url.path, matches: agent) else {
            let alert = NSAlert()
            alert.messageText = String(localized: "terminal.cliMismatch")
            alert.informativeText = format("terminal.cliMismatch.detail", agent.cliCommand ?? "")
            alert.runModal()
            return
        }
        setOverride(url.path)
    }

    private func setOverride(_ path: String?) {
        environment.preferences?.update { preferences in
            var paths = preferences.cliPaths ?? [:]
            paths[agent.kind.rawValue] = path
            preferences.cliPaths = paths.isEmpty ? nil : paths
        }
        environment.launchers.invalidate()
    }
}
