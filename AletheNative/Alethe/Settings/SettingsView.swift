import AletheDesign
import AletheModel
import SwiftUI

/// The standard Settings window (⌘,).
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment
        TabView(selection: $environment.settingsTab) {
            Tab("settings.general.tab", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettings()
            }
            Tab("settings.appearance.tab", systemImage: "paintpalette", value: SettingsTab.appearance) {
                AppearanceSettings()
            }
            Tab("settings.agents.tab", systemImage: "sparkles", value: SettingsTab.agents) {
                AgentSettings()
            }
            Tab("settings.resources.tab", systemImage: "memorychip", value: SettingsTab.resources) {
                ResourceSettings()
            }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

/// The Settings pane shown; Home's setup steps open a given one.
enum SettingsTab: Hashable {
    case general, appearance, agents, resources
}

private struct GeneralSettings: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmClear = false

    var body: some View {
        Form {
            Toggle(isOn: binding(\.alwaysStartUnrestricted)) {
                Text("settings.general.alwaysUnrestricted")
                Text("settings.general.alwaysUnrestricted.help")
            }
            .disabled(environment.preferences == nil)
            .accessibilityIdentifier("settings.alwaysUnrestricted")
            Toggle(isOn: optional(\.startClean, default: false)) {
                Text("settings.general.startClean")
                Text("settings.general.startClean.help")
            }
            .accessibilityIdentifier("settings.startClean")
            Toggle(isOn: optional(\.startOnHome, default: false)) {
                Text("settings.general.startOnHome")
                Text("settings.general.startOnHome.help")
            }
            .accessibilityIdentifier("settings.startOnHome")
            Toggle(isOn: optional(\.confirmQuit, default: true)) {
                Text("settings.general.confirmQuit")
                Text("settings.general.confirmQuit.help")
            }
            .accessibilityIdentifier("settings.confirmQuit")
            Toggle(isOn: optional(\.notifyAgents, default: true)) {
                Text("settings.general.notifyAgents")
                Text("settings.general.notifyAgents.help")
            }
            .accessibilityIdentifier("settings.notifyAgents")
            LabeledContent {
                Button("settings.general.clearActivity") { confirmClear = true }
                    .accessibilityIdentifier("settings.clearActivity")
            } label: {
                Text("settings.general.activity")
                Text("settings.general.activity.help")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(Text("settings.general.clearActivity.confirm"), isPresented: $confirmClear) {
            Button("settings.general.clearActivity", role: .destructive) { environment.activity.clear() }
        }
    }

    private func optional(_ keyPath: WritableKeyPath<PreferencesDocument, Bool?>, default value: Bool) -> Binding<Bool> {
        Binding {
            environment.preferences?.document[keyPath: keyPath] ?? value
        } set: { newValue in
            environment.preferences?.update { $0[keyPath: keyPath] = newValue == value ? nil : newValue }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<PreferencesDocument, Bool>) -> Binding<Bool> {
        Binding {
            environment.preferences?.document[keyPath: keyPath] ?? false
        } set: { value in
            environment.preferences?.update { $0[keyPath: keyPath] = value }
        }
    }
}
