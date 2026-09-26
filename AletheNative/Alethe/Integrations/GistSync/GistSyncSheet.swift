import AletheDesign
import AletheIntegrations
import AppKit
import SwiftUI

/// The GitHub Sync sheet (`EditorRequest.gistSync`; upstream `SyncModal` GitHub card — the cloud card
/// is SET-6, not ported): connect with a token, push, pull (asks once: it replaces this profile's
/// workspace and relaunches), last push and pull, disconnect. A pulled Tauri gist opens the Tauri
/// import in place. The token is never shown once entered.
struct GistSyncSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @State private var token = ""
    @State private var askingPull = false
    @State private var pullStarted = false

    private var sync: GistSyncController { environment.gistSync }

    var body: some View {
        Group {
            if let pull = sync.tauriPull, let workspace = environment.workspace {
                // The main window's undo manager: the import stays undoable once the sheet closes.
                TauriImportSheet(workspace: workspace, undoManager: NSApp.mainWindow?.undoManager,
                                 projectsFile: pull.projectsFile)
            } else {
                form
            }
        }
        .accessibilityIdentifier("gistSync.sheet")
        .onAppear { sync.refresh() }
        .onDisappear { sync.close() }
    }

    private var form: some View {
        Form {
            Section {
                if sync.connected {
                    connectedContent
                } else {
                    connectContent
                }
            } header: {
                Text("gistSync.github")
            } footer: {
                Text("gistSync.subtitle")
                    .foregroundStyle(theme[.textSecondary])
            }
            if let error = sync.error {
                Text(verbatim: error)
                    .foregroundStyle(theme[.statusStopped])
                    .textSelection(.enabled)
                    .accessibilityIdentifier("gistSync.error")
            } else if sync.notice == .pushed {
                Text("gistSync.pushDone")
                    .foregroundStyle(theme[.textSecondary])
                    .accessibilityIdentifier("gistSync.notice")
            }
        }
        .formStyle(.grouped)
        .frame(width: metrics.size(480))
        .navigationTitle(Text("gistSync.title"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("gistSync.done") { dismiss() }
                    .accessibilityIdentifier("gistSync.done")
            }
        }
        .confirmationDialog(Text("gistSync.pull.confirm"), isPresented: $askingPull) {
            Button("gistSync.pull.action", role: .destructive) {
                pullStarted = true
                sync.confirmPull()
            }
            .accessibilityIdentifier("gistSync.pullConfirm")
        } message: {
            Text(verbatim: sync.confirmingPull.map(pullSummary) ?? "")
        }
        .onChange(of: sync.confirmingPull != nil) { _, staged in
            if staged {
                pullStarted = false
                askingPull = true
            }
        }
        .onChange(of: askingPull) { _, shown in
            // Cancelled: the staged copy is dropped and nothing changed.
            if !shown, !pullStarted { sync.cancelPull() }
        }
    }

    // MARK: - Not connected

    @ViewBuilder
    private var connectContent: some View {
        Text("gistSync.description")
            .foregroundStyle(theme[.textSecondary])
        SecureField("gistSync.token", text: $token, prompt: Text("gistSync.token.placeholder"))
            .onSubmit(connect)
            .accessibilityIdentifier("gistSync.token")
        LabeledContent {
            Button(action: connect) {
                if sync.busy == .connect {
                    Text("gistSync.connecting")
                } else {
                    Text("gistSync.connect")
                }
            }
            .disabled(sync.busy != nil || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("gistSync.connect")
        } label: {
            HStack(spacing: metrics.size(4)) {
                Text("gistSync.token.hint")
                Button("gistSync.createToken") { NSWorkspace.shared.open(GistSyncController.createTokenURL) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("gistSync.createToken")
            }
        }
    }

    private func connect() {
        let value = token
        // Cleared at once: the token is never shown again after entry.
        token = ""
        sync.connect(token: value)
    }

    // MARK: - Connected

    @ViewBuilder
    private var connectedContent: some View {
        LabeledContent {
            if let url = sync.status?.gistURL {
                Button("gistSync.openGist") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("gistSync.openGist")
            }
        } label: {
            HStack(spacing: metrics.size(6)) {
                Circle()
                    .fill(theme[.statusActive])
                    .frame(width: metrics.size(7), height: metrics.size(7))
                    .accessibilityHidden(true)
                Text(verbatim: String(format: String(localized: "gistSync.connectedAs"), sync.status?.login ?? "—"))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("gistSync.connectedAs")
        }
        LabeledContent {
            HStack {
                Button(action: sync.push) {
                    if sync.busy == .push {
                        Label("gistSync.pushing", systemImage: "arrow.up.circle")
                    } else {
                        Label("gistSync.push", systemImage: "arrow.up.circle")
                    }
                }
                .accessibilityIdentifier("gistSync.push")
                Button(action: sync.pull) {
                    if sync.busy == .pull {
                        Label("gistSync.pulling", systemImage: "arrow.down.circle")
                    } else {
                        Label("gistSync.pull", systemImage: "arrow.down.circle")
                    }
                }
                .accessibilityIdentifier("gistSync.pull")
            }
            .disabled(sync.busy != nil)
        } label: {
            Text(verbatim: when("gistSync.lastPush", sync.status?.lastPushAt))
                .accessibilityIdentifier("gistSync.lastPush")
            Text(verbatim: when("gistSync.lastPull", sync.status?.lastPullAt))
                .accessibilityIdentifier("gistSync.lastPull")
        }
        LabeledContent {
            Button("gistSync.disconnect", role: .destructive, action: sync.disconnect)
                .disabled(sync.busy != nil)
                .accessibilityIdentifier("gistSync.disconnect")
        } label: {
            Text("gistSync.disconnect.help")
        }
    }

    private func when(_ key: String.LocalizationValue, _ date: Date?) -> String {
        let value = date?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "gistSync.never")
        return String(format: String(localized: key), value)
    }

    private func pullSummary(_ pull: StagedGistPull) -> String {
        [String(format: String(localized: "gistSync.pull.holds"), pull.projects, pull.terminals),
         String(format: String(localized: "gistSync.pull.message"), environment.activeProfileName)]
            .joined(separator: "\n\n")
    }
}
