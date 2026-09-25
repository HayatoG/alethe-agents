import AletheDesign
import AletheFoundation
import AletheTodos
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Todos settings (upstream `TodoSettingsModal`, P4-16/P4-17): the template folder with Open, Import
/// and Export of `alethe-todo.template.jsonc`, the Pomodoro lengths, and reset to the default list.
/// Changes apply as they are made. Template files are read and written by the Todos plugin through
/// its filesystem capability.
struct TodosSettingsSheet: View {
    let store: TodoStore
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var choosingFolder = false
    @State private var confirming: Confirmation?
    @State private var busy = false
    @State private var message: String?
    @State private var error: String? { didSet { if error != oldValue { AppLog.shown(error, .integrations) } } }

    private enum Confirmation: Identifiable {
        case importTemplate, exportTemplate, reset
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.space(.l)) {
            Text("todos.settings.title").font(.headline)
            Form {
                Section("todos.settings.template") {
                    HStack {
                        TextField("todos.settings.folder", text: $path, prompt: Text("todos.settings.folder.placeholder"))
                            .onSubmit { Task { await savePath() } }
                            .accessibilityIdentifier("todos.settings.folder")
                        Button("todos.settings.choose") { choosingFolder = true }
                        Button("todos.settings.clear") {
                            path = ""
                            Task { await savePath() }
                        }
                        .disabled(path.isEmpty)
                    }
                    if let url = store.templateURL {
                        Text(verbatim: url.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(theme[.textSecondary])
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("todos.settings.open") { Task { await openTemplate() } }
                        Button("todos.settings.import") { confirming = .importTemplate }
                        Button("todos.settings.export") { confirming = .exportTemplate }
                    }
                    .disabled(store.templateURL == nil || busy)
                }
                Section("todos.settings.pomodoro") {
                    minutes("todos.settings.work", \.pomodoroWorkMinutes)
                    minutes("todos.settings.shortBreak", \.pomodoroShortBreakMinutes)
                    minutes("todos.settings.longBreak", \.pomodoroLongBreakMinutes)
                }
                Section {
                    Button("todos.settings.reset", role: .destructive) { confirming = .reset }
                        .accessibilityIdentifier("todos.settings.reset")
                }
            }
            .formStyle(.grouped)
            if let message {
                Text(message).font(.caption).foregroundStyle(theme[.statusActive])
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(theme[.statusStopped]).textSelection(.enabled)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("todos.settings.done") { Task { await close() } }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("todos.settings.done")
            }
        }
        .padding(metrics.space(.xl))
        .frame(width: metrics.size(520))
        .accessibilityIdentifier("todos.settings.sheet")
        .onAppear { path = store.settings.storagePath }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                path = url.path
                Task { await savePath() }
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: confirmingBinding, presenting: confirming) { action in
            Button(confirmationButton(action), role: .destructive) { Task { await perform(action) } }
        } message: { action in
            Text(confirmationMessage(action))
        }
    }

    private func minutes(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<TodoSettings, Int>) -> some View {
        let value = Binding {
            store.settings[keyPath: keyPath]
        } set: { newValue in
            store.updateSettings { $0[keyPath: keyPath] = newValue }
        }
        return Stepper(value: value, in: TodoSettings.minuteRange) {
            LabeledContent(title) {
                Text(verbatim: String(format: String(localized: "todos.settings.minutes"), value.wrappedValue))
                    .monospacedDigit()
            }
        }
    }

    // MARK: Actions

    /// Saves the folder and, like upstream, creates the template there when missing.
    private func savePath() async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        store.updateSettings { $0.storagePath = trimmed }
        guard !trimmed.isEmpty else { return }
        await run { plugin in
            _ = try await plugin.ensureTemplate()
            return nil
        }
    }

    private func openTemplate() async {
        await savePath()
        await run { plugin in
            NSWorkspace.shared.open(try await plugin.ensureTemplate())
            return nil
        }
    }

    private func perform(_ action: Confirmation) async {
        switch action {
        case .importTemplate:
            await savePath()
            await run { plugin in
                try await plugin.importTemplate()
                return String(localized: "todos.settings.imported")
            }
        case .exportTemplate:
            await savePath()
            await run { plugin in
                _ = try await plugin.exportTemplate()
                return String(localized: "todos.settings.exported")
            }
        case .reset:
            store.resetToDefaults()
            message = String(localized: "todos.settings.resetDone")
        }
    }

    private func close() async {
        if path.trimmingCharacters(in: .whitespacesAndNewlines) != store.settings.storagePath { await savePath() }
        if error == nil { dismiss() }
    }

    /// Runs a template operation through the active plugin; shows its message or error.
    private func run(_ operation: (TodosPlugin) async throws -> String?) async {
        guard let plugin = TodosPlugin.activePlugin else {
            error = String(localized: "todos.disabled")
            return
        }
        busy = true
        defer { busy = false }
        do {
            message = try await operation(plugin)
            error = nil
        } catch TodoTemplate.TemplateError.invalidDocument(let detail) {
            error = String(format: String(localized: "todos.settings.invalidTemplate"), detail)
        } catch {
            self.error = String(format: String(localized: "todos.settings.templateError"), error.localizedDescription)
        }
    }

    // MARK: Confirmation (asked once per action)

    private var confirmingBinding: Binding<Bool> {
        Binding { confirming != nil } set: { if !$0 { confirming = nil } }
    }

    private var confirmationTitle: LocalizedStringKey {
        switch confirming {
        case .importTemplate: "todos.settings.import.confirm"
        case .exportTemplate: "todos.settings.export.confirm"
        case .reset, nil: "todos.settings.reset.confirm"
        }
    }

    private func confirmationButton(_ action: Confirmation) -> LocalizedStringKey {
        switch action {
        case .importTemplate: "todos.settings.import"
        case .exportTemplate: "todos.settings.export"
        case .reset: "todos.settings.reset"
        }
    }

    private func confirmationMessage(_ action: Confirmation) -> LocalizedStringKey {
        switch action {
        case .importTemplate: "todos.settings.import.message"
        case .exportTemplate: "todos.settings.export.message"
        case .reset: "todos.settings.reset.message"
        }
    }
}
