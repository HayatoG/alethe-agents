import AletheDesign
import AletheModel
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Add Content (⇧⌘A; upstream `AddContentModal`): puts a file or page pane beside a project's
/// terminals. Only kinds the app can already show are offered; each pane task adds its option.
struct AddContentSheet: View {
    let workspace: WorkspaceModel
    let undoManager: UndoManager?
    let project: ProjectID?
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    /// One way to add content: what it shows, and how its target is chosen.
    struct Option: Identifiable {
        let kind: PaneContent.Kind
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        let symbol: String
        /// Asks for the file or page (a panel, a field…); nil when cancelled.
        let choose: @MainActor (_ project: Project) -> PaneContent?
        var id: PaneContent.Kind { kind }
    }

    /// One entry per pane kind the app can show (a kind's task adds it).
    static let options: [Option] = [
        Option(kind: .markdown, title: "addContent.markdown", detail: "addContent.markdown.detail",
               symbol: "doc.richtext") { project in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = String(localized: "addContent.markdown.picker")
            panel.allowedContentTypes = ["md", "markdown", "mdx"].compactMap { UTType(filenameExtension: $0) }
            panel.directoryURL = URL(filePath: project.folder, directoryHint: .isDirectory)
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return .markdown(path: url.path)
        },
        Option(kind: .image, title: "addContent.media", detail: "addContent.media.detail",
               symbol: "photo.on.rectangle") { project in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = String(localized: "addContent.media.picker")
            panel.allowedContentTypes = [.image, .movie]
            panel.directoryURL = URL(filePath: project.folder, directoryHint: .isDirectory)
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return PaneContent.forFile(url.path) ?? .image(path: url.path)
        },
        Option(kind: .web, title: "addContent.web", detail: "addContent.web.detail", symbol: "globe") { _ in
            let alert = NSAlert()
            alert.messageText = String(localized: "addContent.web.prompt")
            alert.informativeText = String(localized: "addContent.web.hint")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "http://localhost:3000"
            field.stringValue = "http://localhost:3000"
            field.setAccessibilityIdentifier("addContent.web.address")
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "addContent.web.add"))
            alert.addButton(withTitle: String(localized: "editor.cancel"))
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn,
                  let url = WebAddress.normalize(field.stringValue) else { return nil }
            return .web(url: url.absoluteString, options: WebPaneOptions())
        },
        Option(kind: .diff, title: "addContent.diff", detail: "addContent.diff.detail", symbol: "plusminus") { _ in
            .diff(path: nil, staged: false)
        },
        Option(kind: .graphify, title: "addContent.graphify", detail: "addContent.graphify.detail",
               symbol: "point.3.connected.trianglepath.dotted") { _ in
            .graphify
        },
    ]

    /// The options whose feature is on: web pages need the browser feature (P5-3), the code graph
    /// the graphify one.
    static func options(for features: Features) -> [Option] {
        options.filter { option in
            switch option.kind {
            case .web: features.isOn(.browser)
            case .graphify: features.isOn(.graphify)
            default: true
            }
        }
    }

    private var target: Project? {
        project.flatMap { workspace.document.project($0) } ?? workspace.document.projects.first
    }

    var body: some View {
        Form {
            Section {
                ForEach(Self.options(for: environment.features)) { option in
                    Button { add(option) } label: {
                        HStack(spacing: metrics.space(.m)) {
                            Image(systemName: option.symbol)
                                .font(metrics.font(.title3))
                                .foregroundStyle(theme[.accent])
                                .frame(width: metrics.size(28))
                            VStack(alignment: .leading, spacing: metrics.space(.xxs)) {
                                Text(option.title).font(metrics.font(.body).weight(.medium))
                                Text(option.detail).font(metrics.font(.footnote)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(target == nil)
                    .accessibilityIdentifier("addContent.\(option.kind.rawValue)")
                }
            } header: {
                Text("addContent.description")
            }
        }
        .formStyle(.grouped)
        .frame(width: metrics.size(420))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("editor.cancel") { dismiss() }
            }
        }
        .navigationTitle(Text("addContent.title"))
    }

    private func add(_ option: Option) {
        guard let target, let content = option.choose(target) else { return }
        workspace.update(undoManager: undoManager, actionName: String(localized: "undo.addContent")) {
            $0.addPane(to: target.id, content: content)
        }
        dismiss()
    }
}
