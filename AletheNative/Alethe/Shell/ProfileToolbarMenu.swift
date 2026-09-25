import AletheModel
import SwiftUI

/// The toolbar's profile menu (UI-7, upstream `UserProfile`): the running profile's name, the other
/// profiles to switch to (asks once, then relaunches) and Manage Profiles….
struct ProfileToolbarMenu: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings
    @State private var switching: ProfileEntry?

    var body: some View {
        Menu {
            ForEach(environment.profiles?.document.ordered(defaultName: AppEnvironment.defaultProfileName) ?? []) { entry in
                Toggle(isOn: Binding {
                    entry.id == environment.profileID
                } set: { chosen in
                    if chosen, entry.id != environment.profileID { switching = entry }
                }) {
                    Text(verbatim: environment.profileName(entry))
                }
            }
            Divider()
            Button("profiles.menu.manage") {
                environment.settingsTab = .profiles
                openSettings()
            }
            .accessibilityIdentifier("profiles.menu.manage")
        } label: {
            Label {
                Text(verbatim: environment.activeProfileName)
            } icon: {
                Image(systemName: "person.crop.circle")
            }
        }
        .help(Text(verbatim: String(format: String(localized: "profiles.menu.help"), environment.activeProfileName)))
        .accessibilityIdentifier("profiles.menu")
        .confirmationDialog(Text(verbatim: String(format: String(localized: "settings.profiles.switch.confirm"),
                                                  switching.map(environment.profileName) ?? "")),
                            isPresented: Binding { switching != nil } set: { if !$0 { switching = nil } }) {
            Button("settings.profiles.switch") {
                guard let entry = switching else { return }
                Task { try? await environment.switchProfile(to: entry.id) }
            }
        } message: {
            Text("settings.profiles.switch.message")
        }
    }
}
