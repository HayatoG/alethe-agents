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
    let projectID: ProjectID?
    @State private var model: MergeCenterModel?
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
                analyze(model)
            }
        }
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
            List(analysis.conflicts, id: \.path) { conflict in
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
}

/// State of the Merge Center: repository branches, the chosen pair, and the running analysis.
@MainActor @Observable
final class MergeCenterModel {
    let folder: URL
    private(set) var root: URL?
    private(set) var branches: [String] = []
    var source = ""
    var target = ""
    private(set) var stage = MergeCenterStage.analyze
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
            let outcome = await Task.detached {
                do { return Result<MergeAnalysis, Error>.success(
                    try await MergeAnalyzer(root: root).analyze(source: source, target: target)) }
                catch { return .failure(error) }
            }.value
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let result): analysis = result
            case .failure(let failure): error = String(describing: failure)
            }
            running = false
        }
    }

    /// Stops waiting for the running analysis; its disposable worktree is torn down by the analyzer.
    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }
}
