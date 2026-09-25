import AletheDesign
import AletheModel
import SwiftUI

/// The standard Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("settings.general.tab", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("settings.appearance.tab", systemImage: "paintpalette") {
                AppearanceSettings()
            }
            Tab("settings.resources.tab", systemImage: "memorychip") {
                ResourceSettings()
            }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppEnvironment.self) private var environment

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
            Toggle(isOn: optional(\.confirmQuit, default: true)) {
                Text("settings.general.confirmQuit")
                Text("settings.general.confirmQuit.help")
            }
            .accessibilityIdentifier("settings.confirmQuit")
        }
        .formStyle(.grouped)
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
