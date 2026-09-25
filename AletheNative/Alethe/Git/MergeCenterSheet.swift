import AletheDesign
import AletheGit
import AletheMerge
import AletheModel
import SwiftUI

/// Merge Center (P4-10…P4-13; upstream merge plugin) for a project's repository. The Analyze stage
/// trial-merges a source branch into a target in a disposable worktree and lists the conflicts
/// with their class and resolution strategy.
struct MergeCenterSheet: View {
    let workspace: WorkspaceModel
    let undoManager: UndoManager?
    let projectID: ProjectID?
    @State private var model: MergeCenterModel?
    @State private var confirmAbort = false
    @State private var confirmCleanup = false
    @State private var testingBranch = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    private var project: Project? { projectID.flatMap { workspace.document.project($0) } }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Text("merge.noProject")
                    .foregroundStyle(theme[.textSecondary])
                    .padding(metrics.space(.xl))
            }
        }
        .frame(width: metrics.size(560), height: metrics.size(600))
        .navigationTitle(Text("merge.title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("merge.close") { dismiss() }
                    .accessibilityIdentifier("merge.close")
            }
        }
        .task {
            guard let project else { return }
            let model = MergeCenterModel(folder: URL(filePath: project.folder, directoryHint: .isDirectory))
            self.model = model
            await model.load()
        }
        .onDisappear { model?.cancel() }
        .accessibilityIdentifier("merge.center")
    }

    @ViewBuilder
    private func content(_ model: MergeCenterModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            stageHeader(model.stage)
                .padding(metrics.space(.l))
            Divider()
            if let error = model.error {
                Label { Text(verbatim: error).textSelection(.enabled) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(theme[.statusStopped])
                .padding(metrics.space(.m))
                .accessibilityIdentifier("merge.error")
            }
            if model.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.stage {
                case .analyze: analyze(model)
                case .prepare: prepare(model)
                case .validate: validate(model)
                case .finish: finish(model)
                }
            }
        }
        .confirmationDialog("merge.abort.confirm", isPresented: $confirmAbort) {
            Button("merge.abort", role: .destructive) { model.abort() }
        }
        .confirmationDialog("merge.cleanup.confirm", isPresented: $confirmCleanup) {
            Button("merge.cleanup", role: .destructive) { model.forceCleanup() }
        }
        .sheet(isPresented: $testingBranch) {
            BranchTestingSheet(folder: model.folder, initialBranch: model.source)
        }
    }

    // MARK: Shared

    /// Progress with cancel while an operation runs, otherwise the given actions.
    @ViewBuilder
    private func actionRow(_ model: MergeCenterModel, @ViewBuilder _ actions: () -> some View) -> some View {
        HStack {
            if model.running {
                ProgressView().controlSize(.small)
                Text("merge.working").foregroundStyle(theme[.textSecondary])
                Button("merge.cancel") { model.cancel() }
                    .accessibilityIdentifier("merge.cancel")
            } else {
                actions()
            }
            Spacer()
        }
    }

    private func outputBox(_ text: String) -> some View {
        ScrollView {
            Text(verbatim: text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("merge.output")
    }

    private func abortButton(_ model: MergeCenterModel) -> some View {
        Button("merge.abort", role: .destructive) { confirmAbort = true }
            .disabled(model.environment == nil)
            .accessibilityIdentifier("merge.abort")
    }

    // MARK: Prepare

    private func prepare(_ model: MergeCenterModel) -> some View {
        VStack(alignment: .leading, spacing: metrics.space(.m)) {
            actionRow(model) {
                Button("merge.resolveWithAgent") { resolveWithAgent(model) }
                    .disabled(model.environment == nil)
                    .accessibilityIdentifier("merge.resolveWithAgent")
                Button("merge.refresh") { model.refreshConflicts() }
                Button("merge.rebase") { model.rebase() }
                    .accessibilityIdentifier("merge.rebase")
                abortButton(model)
                Button("merge.continue") { model.stage = .validate }
                    .disabled(!model.conflicts.isEmpty)
                    .accessibilityIdentifier("merge.continue")
            }
            if let path = model.environment?.path.path {
                Text(verbatim: path)
                    .font(.caption.monospaced())
                    .foregroundStyle(theme[.textSecondary])
                    .textSelection(.enabled)
            }
            if let note = model.note { outputBox(note).frame(maxHeight: metrics.size(80)) }
            Divider()
            conflictList(model.conflicts)
        }
        .padding(metrics.space(.l))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Opens an agent terminal in the merge environment, primed with the conflict instruction.
    private func resolveWithAgent(_ model: MergeCenterModel) {
        guard let project, let path = model.environment?.path.path else { return }
        let tab = PaneTab(agent: "claude", title: String(localized: "merge.agentPaneName"),
                          workingDirectory: path, initialPrompt: ConflictResolution.agentInstruction())
        workspace.update(undoManager: undoManager, actionName: String(localized: "undo.newTerminal")) {
            $0.addPane(to: project.id, tab: tab)
        }
        dismiss()
    }

    // MARK: Validate

    private func validate(_ model: MergeCenterModel) -> some View {
        VStack(alignment: .leading, spacing: metrics.space(.m)) {
            Text("merge.validate.commands").font(.headline)
            TextEditor(text: Bindable(model).commandsText)
                .font(.body.monospaced())
                .frame(height: metrics.size(90))
                .accessibilityIdentifier("merge.validate.commands")
            actionRow(model) {
                Button("merge.validate.run") { model.validate() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("merge.validate.run")
                abortButton(model)
                Button("merge.continue") { model.stage = .finish }
                    .accessibilityIdentifier("merge.continue")
            }
            outcomeDetails(model)
        }
        .padding(metrics.space(.l))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The last validate/finalize outcome: its message, each command, the probe and the contract check.
    @ViewBuilder
    private func outcomeDetails(_ model: MergeCenterModel) -> some View {
        if model.note != nil || model.outcome != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.space(.m)) {
                    if let note = model.note {
                        Text(verbatim: note)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("merge.output")
                    }
                    if let outcome = model.outcome {
                        ValidationStepsView(steps: outcome.validation?.steps ?? [])
                        if let probe = outcome.validation?.healthProbe { HealthProbeSummaryView(result: probe) }
                        if let warnings = outcome.contractWarnings { ContractWarningsView(warnings: warnings) }
                    }
                }
            }
        } else {
            Spacer()
        }
    }

    // MARK: Finish

    private func finish(_ model: MergeCenterModel) -> some View {
        VStack(alignment: .leading, spacing: metrics.space(.m)) {
            actionRow(model) {
                Button("merge.finalize") { model.finalize() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.environment == nil)
                    .accessibilityIdentifier("merge.finalize")
                abortButton(model)
                Button("merge.cleanup", role: .destructive) { confirmCleanup = true }
                    .disabled(model.environment == nil)
                    .accessibilityIdentifier("merge.cleanup")
            }
            if model.merged {
                Label("merge.merged", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(theme[.statusActive])
            }
            outcomeDetails(model)
        }
        .padding(metrics.space(.l))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Stage header

    private func stageHeader(_ current: MergeCenterStage) -> some View {
        HStack(spacing: metrics.space(.s)) {
            ForEach(Array(MergeCenterStage.allCases.enumerated()), id: \.element) { index, stage in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(theme[.textSecondary])
                }
                Text(stageTitle(stage))
                    .font(.callout.weight(stage == current ? .semibold : .regular))
                    .foregroundStyle(stage == current ? theme[.accent] : theme[.textSecondary])
            }
            Spacer()
        }
        .accessibilityIdentifier("merge.stages")
    }

    private func stageTitle(_ stage: MergeCenterStage) -> LocalizedStringKey {
        switch stage {
        case .analyze: "merge.stage.analyze"
        case .prepare: "merge.stage.prepare"
        case .validate: "merge.stage.validate"
        case .finish: "merge.stage.finish"
        }
    }

    // MARK: Analyze

    private func analyze(_ model: MergeCenterModel) -> some View {
        VStack(alignment: .leading, spacing: metrics.space(.m)) {
            Picker("merge.source", selection: Bindable(model).source) {
                ForEach(model.branches, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .accessibilityIdentifier("merge.source")
            Picker("merge.target", selection: Bindable(model).target) {
                ForEach(model.branches, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .accessibilityIdentifier("merge.target")
            HStack {
                if model.running {
                    ProgressView().controlSize(.small)
                    Text("merge.analyzing").foregroundStyle(theme[.textSecondary])
                    Button("merge.cancel") { model.cancel() }
                        .accessibilityIdentifier("merge.cancel")
                } else {
                    Button("merge.analyze") { model.analyze() }
                        .disabled(!model.canAnalyze)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("merge.analyze")
                }
                Spacer()
            }
            HStack {
                if model.analysis != nil, !model.running {
                    Button("merge.prepare") { model.prepare() }
                        .accessibilityIdentifier("merge.prepare")
                }
                Button("menu.merge.branchTesting") { testingBranch = true }
                    .disabled(model.source.isEmpty || model.running)
                    .accessibilityIdentifier("merge.testBranch")
            }
            Divider()
            if let analysis = model.analysis {
                result(analysis)
            } else {
                Spacer()
            }
        }
        .padding(metrics.space(.l))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func result(_ analysis: MergeAnalysis) -> some View {
        if analysis.clean {
            Label("merge.clean", systemImage: "checkmark.circle.fill")
                .foregroundStyle(theme[.statusActive])
                .accessibilityIdentifier("merge.clean")
            Spacer()
        } else {
            HStack {
                Text("merge.conflicts").font(.headline)
                Text(verbatim: "\(analysis.conflicts.count)")
                    .font(.headline)
                    .foregroundStyle(theme[.statusStopped])
            }
            conflictList(analysis.conflicts)
        }
    }

    private func conflictList(_ conflicts: [ConflictFile]) -> some View {
            List(conflicts, id: \.path) { conflict in
                VStack(alignment: .leading, spacing: metrics.space(.xs)) {
                    HStack {
                        Text(verbatim: conflict.path)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Text(verbatim: conflict.class.variantName)
                            .font(.caption)
                            .foregroundStyle(theme[.accent])
                    }
                    Text(verbatim: conflict.class.strategy)
                        .font(.caption)
                        .foregroundStyle(theme[.textSecondary])
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, metrics.space(.xs))
            }
            .accessibilityIdentifier("merge.conflictList")
    }
}

/// State of the Merge Center: repository branches, the chosen pair, and the running analysis.
@MainActor @Observable
final class MergeCenterModel {
    let folder: URL
    private(set) var root: URL?
    private(set) var branches: [String] = []
    var source = ""
    var target = ""
    var stage = MergeCenterStage.analyze
    private(set) var environment: ConflictEnvironment?
    private(set) var conflicts: [ConflictFile] = []
    /// Validation commands for this run, one per line.
    var commandsText = ""
    /// Output of the last prepare / rebase / validate / finish step.
    private(set) var note: String?
    private(set) var merged = false
    /// The last validate/finalize outcome, for its structured results.
    private(set) var outcome: MergeFinishOutcome?
    private(set) var analysis: MergeAnalysis?
    private(set) var loading = true
    private(set) var running = false
    private(set) var error: String?
    private var task: Task<Void, Never>?

    init(folder: URL) { self.folder = folder }

    var canAnalyze: Bool { root != nil && !source.isEmpty && !target.isEmpty && source != target }

    func load() async {
        defer { loading = false }
        do {
            let root = try await GitRepository.discover(folder)
            self.root = root
            let repository = GitRepository(root: root)
            branches = try await repository.branches().filter { !$0.isRemote }.map(\.name).sorted()
            let current = try await repository.currentBranch()
            target = current ?? branches.first ?? ""
            source = branches.first { $0 != target } ?? ""
            commandsText = ValidationSettings.suggested(for: root).commands.joined(separator: "\n")
        } catch {
            self.error = String(describing: error)
        }
    }

    func analyze() {
        guard let root, canAnalyze else { return }
        let (source, target) = (source, target)
        running = true
        error = nil
        analysis = nil
        task = Task {
            // The analyzer runs git subprocesses; keep it off the main actor.
            let work = Task.detached {
                do { return Result<MergeAnalysis, Error>.success(
                    try await MergeAnalyzer(root: root).analyze(source: source, target: target)) }
                catch { return .failure(error) }
            }
            let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let result): analysis = result
            case .failure(let failure): error = String(describing: failure)
            }
            running = false
        }
    }

    /// Cancels the running operation; the git process is terminated and temporary worktrees torn down.
    private var handle: MergeEnvHandle? {
        environment.map { MergeEnvHandle(id: $0.id, source: source, target: target, conflictPaths: conflicts.map(\.path)) }
    }

    private var settings: ValidationSettings {
        ValidationSettings(commands: commandsText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Runs `operation` off the main actor with the shared progress/cancel state.
    private func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T,
                                      then apply: @escaping @MainActor (T) -> Void) {
        running = true
        error = nil
        task = Task {
            // Detached so git runs off the main actor; cancellation is forwarded so the git
            // process is terminated (GitRunner) and the environment torn down.
            let work = Task.detached { () -> Result<T, Error> in
                do { return .success(try await operation()) } catch { return .failure(error) }
            }
            let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let value): apply(value)
            case .failure(let failure): error = String(describing: failure)
            }
            running = false
        }
    }

    func prepare() {
        guard let root else { return }
        let (source, target) = (source, target)
        perform({ try await ConflictResolution(root: root).prepare(source: source, target: target) }) { env in
            self.environment = env
            self.conflicts = env.conflicts
            self.note = nil
            self.stage = env.clean ? .validate : .prepare
        }
    }

    func refreshConflicts() {
        guard let root, let id = environment?.id else { return }
        perform({ try await ConflictResolution(root: root).conflicts(id: id) }) { self.conflicts = $0 }
    }

    func rebase() {
        guard let root, let id = environment?.id else { return }
        perform({ try await ConflictResolution(root: root).rebaseOntoTarget(id: id) }) { outcome in
            self.note = outcome.output
            if case .conflicted(let files) = outcome { self.conflicts = files }
        }
    }

    func abort() {
        guard let root, let id = environment?.id else { return }
        perform({ try await ConflictResolution(root: root).abort(id: id) }) { _ in self.reset() }
    }

    func validate() {
        guard let root, let handle else { return }
        let settings = settings
        perform({ try await MergeFinisher(root: root).validate(handle, settings: settings) }) { outcome in
            self.note = Self.describe(outcome)
            self.outcome = outcome
        }
    }

    func finalize() {
        guard let root, let handle else { return }
        let settings = settings
        perform({ try await MergeFinisher(root: root).finalize(handle, settings: settings) }) { outcome in
            self.note = Self.describe(outcome)
            self.outcome = outcome
            self.merged = outcome.merged
            if outcome.merged { self.environment = nil }
        }
    }

    func forceCleanup() {
        guard let root, let handle else { return }
        perform({ try await MergeFinisher(root: root).forceCleanup(handle) }) { _ in self.reset() }
    }

    private func reset() {
        environment = nil
        conflicts = []
        note = nil
        outcome = nil
        merged = false
        stage = .analyze
    }

    /// The outcome's headline; commands, probe and contract warnings render separately.
    private static func describe(_ outcome: MergeFinishOutcome) -> String {
        "[\(outcome.stage.rawValue)] \(outcome.output)"
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }
}
