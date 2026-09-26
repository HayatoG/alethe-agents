import AletheDesign
import AletheIntegrations
import AppKit
import SwiftUI

/// Settings › Integrations › Spotify (upstream `IntegrationsPage` `spotify`): the client ID, the secret
/// (Keychain, never shown back), the redirect URI to register, Connect/Disconnect and errors.
struct SpotifySettingsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @State private var secretDraft = ""
    @State private var copied = false

    private var controller: NowPlayingController { environment.nowPlaying }

    private var clientID: Binding<String> {
        Binding { environment.preferences?.document.spotifyClientID ?? "" } set: { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            environment.preferences?.update { $0.spotifyClientID = trimmed.isEmpty ? nil : value }
        }
    }

    var body: some View {
        Section {
            TextField("settings.spotify.clientID", text: clientID)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.spotify.clientID")
            secretRow
            redirectRow
            connectionRow
            if let error = controller.model?.error, !controller.isConnecting {
                Text(verbatim: NowPlayingController.message(error))
                    .font(metrics.font(.footnote))
                    .foregroundStyle(theme[.statusStopped])
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.spotify.error")
            }
        } header: {
            Text(verbatim: "Spotify")
        } footer: {
            Text("settings.spotify.footer")
                .font(metrics.font(.footnote))
                .foregroundStyle(theme[.textSecondary])
        }
        .task {
            controller.loadSecretStatus()
            await controller.model?.checkStatus()
        }
    }

    private var secretRow: some View {
        LabeledContent {
            HStack {
                SecureField("settings.spotify.secret", text: $secretDraft,
                            prompt: Text(controller.hasClientSecret == true
                                         ? LocalizedStringKey("settings.spotify.secret.stored")
                                         : "settings.spotify.secret.placeholder"))
                    .labelsHidden()
                    .onSubmit(saveSecret)
                    .accessibilityIdentifier("settings.spotify.secret")
                Button("settings.spotify.secret.save", action: saveSecret)
                    .disabled(secretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.spotify.secret.save")
                if controller.hasClientSecret == true {
                    Button("settings.spotify.secret.remove") { controller.setClientSecret("") }
                        .accessibilityIdentifier("settings.spotify.secret.remove")
                }
            }
        } label: {
            Text("settings.spotify.secret")
            Text(controller.hasClientSecret == true ? LocalizedStringKey("settings.spotify.secret.stored")
                                                     : "settings.spotify.secret.help")
        }
    }

    private var redirectRow: some View {
        LabeledContent {
            HStack {
                Text(verbatim: Spotify.redirectURI)
                    .font(metrics.monoFont(size: 12))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.spotify.redirect")
                Button(copied ? LocalizedStringKey("settings.spotify.copied") : "settings.spotify.copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Spotify.redirectURI, forType: .string)
                    copied = true
                }
                .accessibilityIdentifier("settings.spotify.copy")
            }
        } label: {
            Text("settings.spotify.redirect")
            Text("settings.spotify.redirect.help")
        }
    }

    private var connectionRow: some View {
        LabeledContent {
            HStack {
                if controller.isConnecting {
                    ProgressView().controlSize(.small)
                    Button("nowPlaying.cancel") { controller.cancelConnect() }
                        .accessibilityIdentifier("settings.spotify.cancel")
                } else if controller.model?.connected == true {
                    Button("settings.spotify.disconnect") { controller.disconnect() }
                        .accessibilityIdentifier("settings.spotify.disconnect")
                } else {
                    Button("nowPlaying.connect") { controller.connect() }
                        .disabled(controller.model == nil)
                        .accessibilityIdentifier("settings.spotify.connect")
                }
            }
        } label: {
            Text("settings.spotify.connection")
            status
                .accessibilityIdentifier("settings.spotify.status")
        }
    }

    private var status: Text {
        if controller.isConnecting { return Text("nowPlaying.connecting") }
        switch controller.model?.connected {
        case true: return Text("settings.spotify.status.connected")
        case false: return Text("settings.spotify.status.disconnected")
        default: return Text(verbatim: "…")
        }
    }

    private func saveSecret() {
        let value = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        controller.setClientSecret(value)
        secretDraft = ""
    }
}
