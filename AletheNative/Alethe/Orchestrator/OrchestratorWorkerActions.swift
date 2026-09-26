import AletheDesign
import AletheDocuments
import AletheFoundation
import AletheIntegrations
import AletheModel
import AletheOrchestrator
import SwiftUI

/// The selected worker's actions, at the end of its detail on the board (upstream `ApprovalAsk`, the
/// composer and the diff viewer): the pending ask, the steer/send field, the diff, Cancel, Release
/// and Show in Finder. Nothing is answered without a click; failures are shown here and recorded in
/// Diagnostics. A native subagent (`job.native`) has no worker to act on.
struct OrchestratorWorkerActions: View {
    let job: JobSnapshot
    let project: ProjectID
    let board: OrchestratorBoardModel
    let units: BoardUnits

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var answering = false
    @State private var draft = ""
    @State private var sending = false
    @State private var busy = false
    @State private var confirmingCancel = false
    @State private var diffOpen = false
    @State private var diff: WorkerDiffState = .idle
    @State private var failure: WorkerActionFailure? {
        didSet { if let failure, failure != oldValue { AppLog.shown(failure.logLine, .orchestrator) } }
    }

    private var service: OrchestratorService { environment.orchestrator }

    var body: some View {
        if !job.native {
            VStack(alignment: .leading, spacing: units.space(.s)) {
                if job.status == .blocked, let ask = WorkerAsk(job) {
                    askView(ask)
                }
                if WorkerActions.canMessage(job) {
                    composer
                }
                actionRow
                if diffOpen {
                    diffView
                }
                if let failure {
                    failureView(failure)
                }
            }
            .confirmationDialog(Text(verbatim: String(format: String(localized: "orchestrator.cancelConfirmTitle"), job.id)),
                                isPresented: $confirmingCancel, titleVisibility: .visible) {
                Button("orchestrator.cancelConfirm", role: .destructive) { cancel() }
                    .accessibilityIdentifier("orchestrator.cancel.confirm")
                Button("orchestrator.cancelKeep", role: .cancel) {}
                    .accessibilityIdentifier("orchestrator.cancel.keep")
            } message: {
                Text("orchestrator.cancelConfirmMessage")
            }
            .task(id: diffKey) {
                guard diffOpen else { return }
                await loadDiff()
            }
        }
    }

    // MARK: The ask

    private func askView(_ ask: WorkerAsk) -> some View {
        VStack(alignment: .leading, spacing: units.space(.xs)) {
            HStack(spacing: units.space(.xs)) {
                Image(systemName: ask.kind == .fileChange ? "doc.badge.ellipsis" : "terminal")
                    .accessibilityHidden(true)
                Text("orchestrator.askLabel")
                    .textCase(.uppercase)
                    .tracking(units.size(1))
            }
            .font(units.font(.caption).weight(.bold))
            .foregroundStyle(theme[.statusWaiting])

            Text(ask.kind == .fileChange ? "orchestrator.askFileChange" : "orchestrator.askCommand")
                .font(units.font(.footnote).weight(.medium))
                .foregroundStyle(theme[.textPrimary])
            if let command = ask.command {
                Text(verbatim: command)
                    .font(units.font(.caption).monospaced())
                    .foregroundStyle(theme[.textPrimary])
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, units.space(.s))
                    .padding(.vertical, units.space(.xxs))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme[.bgSunken], in: RoundedRectangle(cornerRadius: units.radius(.sm)))
                    .help(Text(verbatim: command))
                    .accessibilityIdentifier("orchestrator.worker.\(job.id).askCommand")
            }
            if let reason = ask.reason {
                Text(verbatim: reason)
                    .font(units.font(.footnote))
                    .foregroundStyle(theme[.textSecondary])
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let elsewhere = WorkerActions.elsewhere(ask: ask, job: job) {
                HStack(spacing: units.space(.xxs)) {
                    Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                    Text(verbatim: String(format: String(localized: "orchestrator.askIn"), elsewhere))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(units.font(.caption).weight(.semibold))
                .foregroundStyle(theme[.statusWaiting])
                .help(Text("orchestrator.askOutside"))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("orchestrator.worker.\(job.id).askIn")
            }
            FlowLayout(spacing: units.space(.xs), lineSpacing: units.space(.xs), leading: true) {
                ForEach(WorkerDecision.all) { entry in
                    actionButton(entry.label, help: entry.hint, prominent: entry.decision == .accept,
                                 id: "orchestrator.worker.\(job.id).answer.\(entry.decision.rawValue)") {
                        answer(entry.decision)
                    }
                    .disabled(answering)
                }
            }
            Text("orchestrator.askHint")
                .font(units.font(.caption))
                .foregroundStyle(theme[.textTertiary])
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(units.space(.s))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme[.statusWaitingSoft], in: RoundedRectangle(cornerRadius: units.radius(.sm)))
        .overlay {
            RoundedRectangle(cornerRadius: units.radius(.sm)).strokeBorder(theme[.statusWaiting], lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orchestrator.worker.\(job.id).ask")
    }

    private func answer(_ decision: CodexApprovalDecision) {
        guard !answering else { return }
        answering = true
        failure = nil
        Task {
            defer { answering = false }
            do {
                _ = try await service.answer(job: job.id, decision: decision.rawValue)
            } catch {
                failure = WorkerActionFailure(title: String(localized: "orchestrator.answerFailed"), error: error)
            }
        }
    }

    // MARK: The composer

    private var composer: some View {
        let mode = WorkerMessageMode(job)
        return VStack(alignment: .leading, spacing: units.space(.xxs)) {
            HStack(spacing: units.space(.xs)) {
                TextField(text: $draft, prompt: Text(mode.placeholder)) { Text("orchestrator.messageLabel") }
                    .textFieldStyle(.plain)
                    .font(units.font(.footnote))
                    .foregroundStyle(theme[.textPrimary])
                    .disabled(sending)
                    .onSubmit(send)
                    .accessibilityIdentifier("orchestrator.worker.\(job.id).message")
                Text(mode.label)
                    .textCase(.uppercase)
                    .font(units.font(.caption).weight(.semibold))
                    .foregroundStyle(theme[mode == .steer ? .accent : .textTertiary])
                    .help(Text(mode.hint))
                    .accessibilityIdentifier("orchestrator.worker.\(job.id).mode.\(mode.rawValue)")
                Button(action: send) {
                    Image(systemName: "arrow.turn.down.left")
                        .font(units.font(.caption).weight(.semibold))
                        .frame(width: units.size(18), height: units.size(18))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme[.accent])
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(Text(mode.hint))
                .accessibilityLabel(Text(mode.hint))
                .accessibilityIdentifier("orchestrator.worker.\(job.id).send")
            }
            .padding(.horizontal, units.space(.s))
            .padding(.vertical, units.space(.xs))
            .background(theme[.bgElevated], in: RoundedRectangle(cornerRadius: units.radius(.sm)))
            .overlay {
                RoundedRectangle(cornerRadius: units.radius(.sm)).strokeBorder(theme[.border], lineWidth: 1)
            }
            if mode == .resume {
                Text("orchestrator.resumeNote")
                    .font(units.font(.caption))
                    .foregroundStyle(theme[.textTertiary])
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, WorkerActions.canMessage(job) else { return }
        let steer = WorkerMessageMode(job) == .steer
        sending = true
        failure = nil
        Task {
            defer { sending = false }
            do {
                _ = try await service.message(job: job.id, text: text, steer: steer)
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
            } catch {
                failure = WorkerActionFailure(title: String(localized: "orchestrator.sendFailed"), error: error)
            }
        }
    }

    // MARK: Diff, cancel, release, Finder

    @ViewBuilder private var actionRow: some View {
        let canCancel = WorkerActions.canCancel(job)
        let canRelease = WorkerActions.canRelease(job)
        let worktree = job.worktree
        if job.hasDiff || canCancel || canRelease || worktree != nil {
            FlowLayout(spacing: units.space(.xs), lineSpacing: units.space(.xs), leading: true) {
                if job.hasDiff {
                    actionButton(diffOpen ? "orchestrator.hideDiff" : "orchestrator.viewDiff", help: nil,
                                 id: "orchestrator.worker.\(job.id).diffToggle") {
                        diffOpen.toggle()
                        if !diffOpen { diff = .idle }
                    }
                }
                if canCancel {
                    actionButton("orchestrator.cancelAction", help: "orchestrator.cancelTitle", destructive: true,
                                 id: "orchestrator.worker.\(job.id).cancel") {
                        if WorkerActions.cancelAsks(job) { confirmingCancel = true } else { cancel() }
                    }
                    .disabled(busy)
                }
                if canRelease {
                    actionButton("orchestrator.releaseAction", help: "orchestrator.releaseTitle",
                                 id: "orchestrator.worker.\(job.id).release") { release() }
                        .disabled(busy)
                }
                if let worktree {
                    actionButton("orchestrator.showInFinder", help: nil,
                                 id: "orchestrator.worker.\(job.id).reveal") {
                        OpenInActions.revealInFinder(worktree)
                    }
                    .help(Text(verbatim: worktree))
                    .disabled(!FileManager.default.fileExists(atPath: worktree))
                }
            }
        }
    }

    private func cancel() {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                _ = try await service.cancel(job: job.id)
            } catch {
                failure = WorkerActionFailure(title: String(localized: "orchestrator.cancelFailed"), error: error)
            }
        }
    }

    private func release() {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                _ = try await service.release(job: job.id)
            } catch {
                failure = WorkerActionFailure(title: String(localized: "orchestrator.releaseFailed"), error: error)
            }
        }
    }

    /// Reloads the open diff when the worker moves on (a new turn, a new report of its changes).
    private var diffKey: String {
        "\(diffOpen)|\(job.status.rawValue)|\(job.hasDiff)|\(job.summary.count)"
    }

    /// The text comes from the core, the parse runs off main; the previous diff stays up while a
    /// newer one loads.
    private func loadDiff() async {
        if case .loaded = diff {} else { diff = .loading }
        guard let text = await service.diff(job: job.id) else {
            failure = WorkerActionFailure(title: String(localized: "orchestrator.diffFailed"),
                                          detail: String(format: String(localized: "orchestrator.unknownWorker"), job.id))
            diffOpen = false
            diff = .idle
            return
        }
        let document = await Task.detached(priority: .userInitiated) { DiffParser.parse(text) }.value
        guard !Task.isCancelled, diffOpen else { return }
        diff = .loaded(document)
    }

    @ViewBuilder private var diffView: some View {
        Group {
            switch diff {
            case .idle, .loading:
                Text("orchestrator.diffLoading")
                    .font(units.font(.caption))
                    .foregroundStyle(theme[.textTertiary])
                    .padding(units.space(.s))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .loaded(let document) where document.isEmpty:
                Text("diff.empty")
                    .font(units.font(.caption))
                    .foregroundStyle(theme[.textTertiary])
                    .padding(units.space(.s))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .loaded(let document):
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(document.files) { file in
                            diffFile(file)
                        }
                    }
                    .font(units.font(.caption).monospaced())
                    .textSelection(.enabled)
                }
                .frame(height: diffHeight(document))
            }
        }
        .background(theme[.bg], in: RoundedRectangle(cornerRadius: units.radius(.sm)))
        .clipShape(RoundedRectangle(cornerRadius: units.radius(.sm)))
        .overlay { RoundedRectangle(cornerRadius: units.radius(.sm)).strokeBorder(theme[.borderSubtle], lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orchestrator.worker.\(job.id).diff")
    }

    /// The Diff pane's styling: file header, hunk header on the accent tint, added and removed lines
    /// on the status tints.
    @ViewBuilder private func diffFile(_ file: DiffFile) -> some View {
        Text(verbatim: file.path)
            .font(units.font(.caption).weight(.semibold))
            .foregroundStyle(theme[.textPrimary])
            .padding(.horizontal, units.space(.s))
            .padding(.vertical, units.space(.xxs))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme[.bgElevated])
        ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
            Text(verbatim: hunk.header)
                .foregroundStyle(theme[.accent])
                .padding(.horizontal, units.space(.s))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme[.accentFaint])
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: WorkerActions.diffText(line))
                    .foregroundStyle(theme[line.kind == .note ? .textTertiary : .textPrimary])
                    .fixedSize()
                    .padding(.horizontal, units.space(.s))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(diffBackground(line.kind))
            }
        }
    }

    private func diffBackground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: theme[.statusActive].opacity(0.14)
        case .removed: theme[.statusStopped].opacity(0.14)
        case .context, .note: .clear
        }
    }

    /// Up to about 18 rows tall; a longer diff scrolls inside the card.
    private func diffHeight(_ document: DiffDocument) -> CGFloat {
        let rows = document.files.reduce(0) { total, file in
            total + 1 + file.hunks.reduce(0) { $0 + 1 + $1.lines.count }
        }
        return units.size(CGFloat(min(rows, 18)) * 14 + 4)
    }

    // MARK: Pieces

    private func failureView(_ failure: WorkerActionFailure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: units.space(.xs)) {
            Image(systemName: "exclamationmark.octagon.fill").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: units.size(1)) {
                Text(verbatim: failure.title).font(units.font(.caption).weight(.semibold))
                Text(verbatim: failure.detail).font(units.font(.caption)).lineLimit(3)
            }
            Spacer(minLength: 0)
            Button { self.failure = nil } label: {
                Image(systemName: "xmark").font(units.font(.caption))
            }
            .buttonStyle(.borderless)
            .help(Text("orchestrator.dismissError"))
            .accessibilityLabel(Text("orchestrator.dismissError"))
        }
        .foregroundStyle(theme[.statusOffline])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orchestrator.worker.\(job.id).failure")
    }

    private func actionButton(_ label: LocalizedStringKey, help: LocalizedStringKey?, prominent: Bool = false,
                              destructive: Bool = false, id: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(units.font(.caption).weight(.medium))
                .padding(.horizontal, units.space(.s))
                .padding(.vertical, units.size(3))
                .foregroundStyle(theme[prominent ? .bg : destructive ? .statusOffline : .textPrimary])
                .background(theme[prominent ? .accent : .bgElevated], in: RoundedRectangle(cornerRadius: units.radius(.sm)))
                .overlay {
                    RoundedRectangle(cornerRadius: units.radius(.sm))
                        .strokeBorder(theme[prominent ? .accent : .border], lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help.map { Text($0) } ?? Text(verbatim: ""))
        .accessibilityIdentifier(id)
    }
}

// MARK: - Rules

/// When each action applies (upstream `canMessage`, `messageMode`, `askIn`, plus Cancel/Release).
enum WorkerActions {
    /// Cancelled workers are gone for good. An interrupted or released one is not: a message
    /// starts it again on its thread (`alethe_send` revives a job with no process), which is what
    /// makes Release reversible.
    static func canMessage(_ job: JobSnapshot) -> Bool {
        if job.native { return false }
        switch job.status {
        case .cancelled: return false
        case .interrupted, .released: return job.threadID != nil
        default: return true
        }
    }

    /// Anything not settled can be stopped.
    static func canCancel(_ job: JobSnapshot) -> Bool {
        !job.native && !job.status.settled
    }

    /// Cancelling ends a turn in flight, so it asks once; a queued job just leaves the queue.
    static func cancelAsks(_ job: JobSnapshot) -> Bool {
        job.status == .running || job.status == .blocked
    }

    /// A settled worker that still may hold a process (a parked one, a failed one, an interrupted
    /// one) is let go; its record stays.
    static func canRelease(_ job: JobSnapshot) -> Bool {
        guard !job.native else { return false }
        switch job.status {
        case .done, .failed, .interrupted: return true
        default: return false
        }
    }

    /// The folder an ask runs in when it is outside the worker's own folder (upstream `askIn`).
    static func elsewhere(ask: WorkerAsk, job: JobSnapshot) -> String? {
        guard let cwd = ask.cwd, !cwd.isEmpty else { return nil }
        let own = standardized(job.cwd)
        let asked = standardized(cwd)
        if asked == own || asked.hasPrefix(own.hasSuffix("/") ? own : own + "/") { return nil }
        return cwd
    }

    private static func standardized(_ path: String) -> String {
        URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func diffText(_ line: DiffLine) -> String {
        switch line.kind {
        case .added: "+" + line.text
        case .removed: "-" + line.text
        case .context: " " + line.text
        case .note: line.text
        }
    }
}

/// What a message does to this worker right now (upstream `MessageMode`).
enum WorkerMessageMode: String {
    case steer, resume, next

    init(_ job: JobSnapshot) {
        switch job.status {
        case .running: self = .steer
        case .interrupted, .released: self = .resume
        default: self = .next
        }
    }

    var placeholder: LocalizedStringKey {
        switch self {
        case .steer: "orchestrator.steerPlaceholder"
        case .resume: "orchestrator.resumePlaceholder"
        case .next: "orchestrator.sendPlaceholder"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .steer: "orchestrator.modeSteer"
        case .resume: "orchestrator.modeResume"
        case .next: "orchestrator.modeNext"
        }
    }

    var hint: LocalizedStringKey {
        switch self {
        case .steer: "orchestrator.steerHint"
        case .resume: "orchestrator.resumeHint"
        case .next: "orchestrator.sendHint"
        }
    }
}

/// The question a worker is stopped on, read off `pendingApproval`; nothing is inferred when a field
/// is missing.
struct WorkerAsk: Equatable {
    var kind: CodexApprovalRequest.Kind
    var command: String?
    var cwd: String?
    var reason: String?

    init?(_ job: JobSnapshot) {
        guard let object = job.pendingApproval?.objectValue else { return nil }
        kind = object["kind"]?.stringValue.flatMap(CodexApprovalRequest.Kind.init(rawValue:)) ?? .command
        command = object["command"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        cwd = object["cwd"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        reason = object["reason"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The four answers, in upstream's order.
struct WorkerDecision: Identifiable {
    let decision: CodexApprovalDecision
    let label: LocalizedStringKey
    let hint: LocalizedStringKey
    var id: String { decision.rawValue }

    static var all: [WorkerDecision] {
        [
            WorkerDecision(decision: .accept, label: "orchestrator.answerAccept", hint: "orchestrator.answerAcceptTitle"),
            WorkerDecision(decision: .acceptForSession, label: "orchestrator.answerSession", hint: "orchestrator.answerSessionTitle"),
            WorkerDecision(decision: .decline, label: "orchestrator.answerDecline", hint: "orchestrator.answerDeclineTitle"),
            WorkerDecision(decision: .abort, label: "orchestrator.answerAbort", hint: "orchestrator.answerAbortTitle"),
        ]
    }
}

enum WorkerDiffState: Equatable {
    case idle, loading
    case loaded(DiffDocument)
}

struct WorkerActionFailure: Equatable {
    var title: String
    var detail: String

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    init(title: String, error: any Error) {
        self.title = title
        detail = (error as? OrchestratorToolError)?.message ?? error.localizedDescription
    }

    var logLine: String { "\(title): \(detail)" }
}

// MARK: - Service

extension OrchestratorService {
    /// Stops a worker that has not settled (upstream `alethe_cancel`): its turn is interrupted and
    /// it ends as cancelled.
    func cancel(job: String) async throws -> OrderedJSON {
        try await boardTool("alethe_cancel", ["jobIds": .array([.string(job)])])
    }

    /// Lets go of a worker that is not running a turn (upstream `alethe_release`): its process ends,
    /// its record and thread stay, so a message starts it again.
    func release(job: String) async throws -> OrderedJSON {
        try await boardTool("alethe_release", ["jobIds": .array([.string(job)])])
    }

    private func boardTool(_ name: String, _ arguments: OrderedJSONObject) async throws -> OrderedJSON {
        guard let core = await prepared() else { throw OrchestratorToolError("the orchestrator is not running") }
        return try await core.callTool(name: name, arguments: arguments, planner: nil)
    }
}
