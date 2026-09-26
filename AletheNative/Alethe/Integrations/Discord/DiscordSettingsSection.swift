import SwiftUI

/// Settings › Integrations › Discord (upstream `IntegrationsPage` `discord`): Rich Presence on or off.
struct DiscordSettingsSection: View {
    @Environment(AppEnvironment.self) private var environment

    private var enabled: Binding<Bool> {
        Binding { environment.preferences?.document.showsDiscordPresence ?? false } set: { on in
            environment.preferences?.update { $0.discordPresence = on ? true : nil }
        }
    }

    var body: some View {
        Section("settings.discord.title") {
            Toggle(isOn: enabled) {
                Text("settings.discord.presence")
                Text("settings.discord.presence.help")
            }
            .disabled(environment.preferences == nil)
            .accessibilityIdentifier("settings.discord.presence")
        }
    }
}
