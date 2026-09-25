import AletheDesign
import AletheGit
import AletheModel
import SwiftUI

/// Git Control (P4-5; upstream `plugins/git-control`) for a project's folder: changes grouped
/// staged / unstaged / conflicts, stage and discard, commit with amend, branch switcher, and
/// fetch / pull / push. Clicking a file opens its diff in a diff pane of the project.
struct GitControlSheet: View {
    let workspace: WorkspaceModel
    let undoManager: UndoManager?
    let projectID: ProjectID?
    @State private var model: GitControlModel?
    @State private var pendingDiscard: GitStatusEntry?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    private var project: Project? { projectID.flatMap { workspace.document.project($0) } }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Text("git.noProject")
                    .foregroundStyle(theme[.textSecondary])
                    .padding(metrics.space(.xl))
            }
        }
        .frame(width: metrics.size(520), height: metrics.size(600))
        .navigationTitle(Text("git.title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("git.close") { dismiss() }
                    .accessibilityIdentifier("git.close")
            }
        }
        .task {
            guard let project else { return }
            let model = GitControlModel(folder: URL(filePath: project.folder, directoryHint: .isDirectory))
            self.model = model
            await model.start()
        }
        .onDisappear { model?.stop() }
        .accessibilityIdentifier("git.control")
    }

    @ViewBuilder
    private func content(_ model: GitControlModel) -> some View {
        VStack(spacing: 0) {
            if let error = model.error {
                errorBanner(error, model)
            }
            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notARepository:
                notARepository(model)
            case .ready:
                repositoryView(model)
            }
        }
    }

    private func errorBanner(_ error: String, _ model: GitControlModel) -> some View {
        HStack(alignment: .top) {
            Label {
                Text(verbatim: error).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(theme[.statusStopped])
            Spacer()
            Button { model.dismissError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("git.dismissError"))
        }
        .padding(metrics.space(.m))
        .accessibilityIdentifier("git.error")
    }

    private func notARepository(_ model: GitControlModel) -> some View {
        VStack(spacing: metrics.space(.l)) {
            Text("git.notARepository")
                .foregroundStyle(theme[.textSecondary])
            Button("git.initialize") { model.initialize() }
                .disabled(model.busy)
                .accessibilityIdentifier("git.initialize")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Repository

    private func repositoryView(_ model: GitControlModel) -> some View {
        VStack(spacing: 0) {
            header(model)
            Divider()
            changes(model)
            Divider()
            commitBox(model)
        }
    }

    private func header(_ model: GitControlModel) -> some View {
        let branch = model.status?.branch
        return VStack(alignment: .leading, spacing: metrics.space(.s)) {
            HStack(spacing: metrics.space(.m)) {
                Menu {
                    ForEach(model.branches) { item in
                        Button(item.name) { model.switchBranch(item.name) }
                            .disabled(item.isCurrent)
                    }
                } label: {
                    Label {
                        if let head = branch?.head {
                            Text(verbatim: head)
                        } else {
                            Text("git.detached")
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                }
                .fixedSize()
                .disabled(model.busy || model.branches.isEmpty)
                .accessibilityIdentifier("git.branch")
                if let branch, branch.ahead > 0 || branch.behind > 0 {
                    Text(verbatim: "↑\(branch.ahead) ↓\(branch.behind)")
                        .font(metrics.font(.caption).monospacedDigit())
                        .foregroundStyle(theme[.textSecondary])
                        .accessibilityIdentifier("git.aheadBehind")
                }
                Spacer()
                remoteButton(model, .fetch, symbol: "arrow.triangle.2.circlepath", label: "git.fetch")
                remoteButton(model, .pull, symbol: "arrow.down", label: "git.pull")
                remoteButton(model, .push, symbol: "arrow.up", label: "git.push")
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(Text("git.refresh"))
                    .accessibilityLabel(Text("git.refresh"))
                    .accessibilityIdentifier("git.refresh")
            }
            if model.remoteAction != nil {
                HStack(spacing: metrics.space(.s)) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: model.progress ?? String(localized: "git.working"))
                        .font(metrics.font(.caption))
                        .foregroundStyle(theme[.textSecondary])
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityIdentifier("git.progress")
            }
        }
        .padding(metrics.space(.l))
    }

    private func remoteButton(_ model: GitControlModel, _ action: GitControlModel.RemoteAction,
                              symbol: String, label: LocalizedStringKey) -> some View {
        Button { model.remote(action) } label: { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .disabled(model.remoteAction != nil)
            .help(Text(label))
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier("git.\(action)")
    }

    private func changes(_ model: GitControlModel) -> some View {
        let status = model.status
        let conflicts = status?.conflicts ?? []
        let staged = status?.staged ?? []
        let unstaged = status?.entries.filter { $0.isUnstaged || $0.isUntracked } ?? []
        return List {
            if status?.isClean ?? true {
                Text("git.clean")
                    .foregroundStyle(theme[.textSecondary])
                    .accessibilityIdentifier("git.clean")
            }
            if !conflicts.isEmpty {
                Section("git.conflicts") {
                    ForEach(conflicts, id: \.path) { entry in
                        row(entry, model, staged: false) {
                            rowButton("plus", "git.markResolved") { model.stage([entry.path]) }
                        }
                    }
                }
            }
            if !staged.isEmpty {
                Section {
                    ForEach(staged, id: \.path) { entry in
                        row(entry, model, staged: true) {
                            rowButton("minus", "git.unstage") { model.unstage([entry.path]) }
                        }
                    }
                } header: {
                    sectionHeader("git.staged", count: staged.count, action: "git.unstageAll") { model.unstageAll() }
                }
            }
            if !unstaged.isEmpty {
                Section {
                    ForEach(unstaged, id: \.path) { entry in
                        row(entry, model, staged: false) {
                            rowButton("arrow.uturn.backward", "git.discard") { pendingDiscard = entry }
                            rowButton("plus", "git.stage") { model.stage([entry.path]) }
                        }
                    }
                } header: {
                    sectionHeader("git.changes", count: unstaged.count, action: "git.stageAll") { model.stageAll() }
                }
            }
        }
        .listStyle(.inset)
        .disabled(model.busy)
        .accessibilityIdentifier("git.changesList")
        .confirmationDialog(Text("git.discard.title"), isPresented: discardPresented, presenting: pendingDiscard) { entry in
            Button("git.discard.confirm", role: .destructive) { model.discard(entry) }
                .accessibilityIdentifier("git.discard.confirm")
            Button("editor.cancel", role: .cancel) {}
        } message: { entry in
            Text(verbatim: format("git.discard.message", entry.path))
        }
    }

    private var discardPresented: Binding<Bool> {
        Binding { pendingDiscard != nil } set: { if !$0 { pendingDiscard = nil } }
    }

    private func sectionHeader(_ title: LocalizedStringKey, count: Int, action: LocalizedStringKey,
                               perform: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Text(verbatim: "\(count)").foregroundStyle(theme[.textSecondary])
            Spacer()
            Button(action, action: perform)
                .buttonStyle(.borderless)
                .font(metrics.font(.caption))
        }
    }

    private func row<Actions: View>(_ entry: GitStatusEntry, _ model: GitControlModel, staged: Bool,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: metrics.space(.m)) {
            Text(verbatim: badge(entry, staged: staged))
                .font(metrics.font(.caption).monospaced().weight(.semibold))
                .foregroundStyle(badgeColor(entry, staged: staged))
                .frame(width: metrics.size(14))
            Button { openDiff(entry, staged: staged) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: (entry.path as NSString).lastPathComponent)
                        .lineLimit(1)
                    let directory = (entry.path as NSString).deletingLastPathComponent
                    if !directory.isEmpty {
                        Text(verbatim: directory)
                            .font(metrics.font(.caption))
                            .foregroundStyle(theme[.textSecondary])
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("git.openDiff"))
            actions()
        }
        .accessibilityIdentifier("git.file.\(entry.path)")
    }

    private func rowButton(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(Text(label))
            .accessibilityLabel(Text(label))
    }

    private func badge(_ entry: GitStatusEntry, staged: Bool) -> String {
        if entry.isConflict { return "!" }
        if entry.isUntracked { return "U" }
        let change = staged ? entry.index : entry.worktree
        return switch change {
        case .added?: "A"
        case .deleted?: "D"
        case .renamed?: "R"
        default: "M"
        }
    }

    private func badgeColor(_ entry: GitStatusEntry, staged: Bool) -> Color {
        if entry.isConflict { return theme[.statusStopped] }
        return entry.isUntracked || (staged ? entry.index : entry.worktree) == .added
            ? theme[.statusActive] : theme[.textSecondary]
    }

    private func commitBox(_ model: GitControlModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: metrics.space(.m)) {
            TextField("git.commitMessage", text: $model.message, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("git.message")
            HStack {
                Toggle("git.amend", isOn: $model.amend)
                    .accessibilityIdentifier("git.amend")
                Spacer()
                Button("git.commit") { model.commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canCommit)
                    .accessibilityIdentifier("git.commit")
            }
        }
        .padding(metrics.space(.l))
    }

    /// Opens the file's diff in a new diff pane of the project, then closes the sheet.
    private func openDiff(_ entry: GitStatusEntry, staged: Bool) {
        guard let projectID else { return }
        workspace.update(undoManager: undoManager, actionName: String(localized: "undo.addContent")) {
            _ = $0.addPane(to: projectID, content: .diff(path: entry.path, staged: staged))
        }
        dismiss()
    }
}
