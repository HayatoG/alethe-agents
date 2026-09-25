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
        }
        .formStyle(.grouped)
    }

    private func binding(_ keyPath: WritableKeyPath<PreferencesDocument, Bool>) -> Binding<Bool> {
        Binding {
            environment.preferences?.document[keyPath: keyPath] ?? false
        } set: { value in
            environment.preferences?.update { $0[keyPath: keyPath] = value }
        }
    }
}
