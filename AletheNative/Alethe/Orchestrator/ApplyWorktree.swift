import AletheFoundation
import AletheGit
import AletheMerge
import AletheOrchestrator
import Foundation
import Observation

/// Where one worker's apply stands, as its detail on the board shows it.
enum ApplyWorktreePhase: Equatable {
    case idle
    /// Reading what the apply would change.
    case previewing
    /// Waiting for the one confirmation, with what will change.
    case confirming(WorktreeApplyPreview)
    case running(WorktreeApplyStep)
    case applied(target: String)
    case nothingToApply
    /// Conflicts or a stopped merge: continued in the Merge Center on this environment.
    case handedOff(environmentID: String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .previewing, .running: true
        default: false
        }
    }
}

/// Applying finished workers' worktrees into their project's branch (P6-16; upstream
/// `OrchestratorPane` `applyWorktree`). One per app: applies outlive the board pane that started
/// them, and a job stays marked applied for the rest of the session (upstream's `applied` set). Git
/// runs off the main actor through `WorktreeApply`; cancel works until the merge step.
@Observable
@MainActor
final class ApplyWorktreeCenter {
    static let shared = ApplyWorktreeCenter()

    private(set) var phases: [String: ApplyWorktreePhase] = [:]
    @ObservationIgnored var operations: WorktreeApplyOperations = .live()
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [String: Int] = [:]

    func phase(_ job: String) -> ApplyWorktreePhase { phases[job] ?? .idle }

    /// Reads what applying `job` would change, then waits for the confirmation.
    func review(_ job: JobSnapshot) {
        guard let path = job.worktree, !phase(job.id).isBusy else { return }
        if case .applied = phase(job.id) { return }
        let apply = WorktreeApply(operations: operations)
        let (id, worktree) = (job.id, URL(filePath: path, directoryHint: .isDirectory))
        start(id, .previewing) { generation in
            let result = await Task.detached { () -> Result<WorktreeApplyPreview, Error> in
                do { return .success(try await apply.preview(worktree: worktree, agentID: id)) } catch { return .failure(error) }
            }.value
            guard self.isCurrent(id, generation) else { return }
            switch result {
            case .success(let preview): self.phases[id] = .confirming(preview)
            case .failure(let error): self.fail(id, error)
            }
        }
    }

    /// The confirmation: commits, analyzes, prepares and finalizes. A conflict or a stopped merge
    /// calls `openMergeCenter` with the prepared environment.
    func confirm(_ job: String, projectID: String?, bus: EventBus?, openMergeCenter: @escaping @MainActor @Sendable (String) -> Void) {
        guard case .confirming(let preview) = phase(job) else { return }
        let apply = WorktreeApply(operations: operations)
        start(job, .running(.committing)) { generation in
            let events = EventOutbox(bus: bus)
            let work = Task.detached { () -> Result<WorktreeApplyResult, Error> in
                do {
                    return .success(try await apply.run(preview, projectID: projectID) { step in
                        Task { @MainActor in self.advance(job, generation, to: step) }
                    })
                } catch { return .failure(error) }
            }
            let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard self.isCurrent(job, generation) else { return }
            self.tasks[job] = nil
            switch outcome {
            case .success(let result):
                Self.publish(result, preview: preview, projectID: projectID, to: events)
                self.finish(job, result, preview: preview, openMergeCenter: openMergeCenter)
            case .failure(let error):
                self.fail(job, error)
            }
        }
    }

    /// Closes the confirmation, or stops a running apply before its merge step.
    func cancel(_ job: String) {
        switch phase(job) {
        case .previewing, .confirming:
            stop(job)
            phases[job] = nil
        case .running(let step) where step.isCancelable:
            tasks[job]?.cancel()
        default:
            break
        }
    }

    /// Clears a finished note (failure, nothing to apply, hand-off) so the action shows again.
    func dismiss(_ job: String) {
        switch phase(job) {
        case .failed, .nothingToApply, .handedOff: phases[job] = nil
        default: break
        }
    }

    // MARK: Private

    private func start(_ job: String, _ phase: ApplyWorktreePhase, _ body: @escaping @MainActor @Sendable (Int) async -> Void) {
        stop(job)
        let generation = (generations[job] ?? 0) + 1
        generations[job] = generation
        phases[job] = phase
        tasks[job] = Task { await body(generation) }
    }

    private func stop(_ job: String) {
        tasks[job]?.cancel()
        tasks[job] = nil
        generations[job, default: 0] += 1
    }

    private func isCurrent(_ job: String, _ generation: Int) -> Bool { generations[job] == generation }

    private func advance(_ job: String, _ generation: Int, to step: WorktreeApplyStep) {
        guard isCurrent(job, generation), case .running = phase(job) else { return }
        phases[job] = .running(step)
    }

    private func finish(_ job: String, _ result: WorktreeApplyResult, preview: WorktreeApplyPreview,
                        openMergeCenter: @MainActor (String) -> Void) {
        switch result.outcome {
        case .applied:
            phases[job] = .applied(target: preview.target)
        case .nothingToApply:
            phases[job] = .nothingToApply
        case .cancelled:
            phases[job] = nil
        case .conflicted(let environment):
            phases[job] = .handedOff(environmentID: environment)
            openMergeCenter(environment)
        case .notMerged(let environment, let stage, let output):
            AppLog.shown("Applying \(job) stopped at \(stage.rawValue): \(output)", .orchestrator, level: .warning)
            phases[job] = .handedOff(environmentID: environment)
            openMergeCenter(environment)
        }
    }

    private func fail(_ job: String, _ error: Error) {
        tasks[job] = nil
        let message = Self.describe(error)
        AppLog.shown("Applying \(job) failed: \(message)", .orchestrator)
        phases[job] = .failed(message)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case WorktreeApplyError.detachedTarget:
            String(localized: "orchestrator.apply.error.detached")
        case WorktreeApplyError.sameBranch(let branch):
            String(format: String(localized: "orchestrator.apply.error.sameBranch"), branch)
        case GitWorktreeError.notFound:
            String(localized: "orchestrator.apply.error.gone")
        default:
            String(describing: error)
        }
    }

    /// The Merge Center's events for the steps this apply took (P6-19).
    private static func publish(_ result: WorktreeApplyResult, preview: WorktreeApplyPreview, projectID: String?,
                                to events: EventOutbox) {
        if let analysis = result.analysis {
            events.publish(.mergeAnalyzed(projectID: projectID, source: analysis.source, target: analysis.target,
                                          clean: analysis.clean, conflictCount: analysis.conflicts.count,
                                          classes: analysis.classes.map(\.variantName)))
        }
        guard let environment = result.environment else { return }
        events.publish(BusEvent.mergePrepared(
            environmentID: environment.id, projectID: projectID, source: preview.source, target: preview.target,
            clean: environment.clean, conflictCount: environment.conflicts.count, environmentPath: environment.path.path))
        if result.outcome == .applied {
            events.publish(.mergeMerged(environmentID: environment.id, projectID: projectID,
                                        source: preview.source, target: preview.target))
        }
    }
}
