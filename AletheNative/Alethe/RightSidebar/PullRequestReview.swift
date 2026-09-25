import AletheAgents
import AletheDesign
import AletheGit
import AletheModel
import SwiftUI

/// Head SHAs recorded when a PR review started, plus the last review agent/model (P4-15). In memory
/// only: a squash merge must follow a review from this launch.
@MainActor @Observable
final class PullRequestReviewState {
    static let shared = PullRequestReviewState()

    private(set) var reviewedHeads: [String: String] = [:]
    var agent: AgentKind = .claude
    var model = ""

    func record(_ pr: PullRequestSummary, headSHA: String) { reviewedHeads[pr.id] = headSHA }
    func reviewedHead(_ pr: PullRequestSummary) -> String? { reviewedHeads[pr.id] }
    func forget(_ pr: PullRequestSummary) { reviewedHeads[pr.id] = nil }

    /// Agent-facing prompt (upstream `pullRequestReviewPrompt`); never commits, pushes or merges.
    static func prompt(for pr: PullRequestSummary, headSHA: String) -> String {
        let url = pr.browserURL?.absoluteString ?? "https://github.com/\(pr.repo)/pull/\(pr.number)"
        return "Review Pull Request #\(pr.number) in \(pr.repo): \"\(pr.title)\" (\(url)). "
            + "The reviewed remote head SHA is \(headSHA). "
            + "Use `gh pr diff \(pr.number) -R \(pr.repo)` and `gh pr view \(pr.number) -R \(pr.repo)` "
            + "and inspect the changed files. "
            + "Look for bugs, security risks, broken contracts, missing tests and compatibility problems. "
            + "Do not commit, push, merge or comment on GitHub. Only present objective findings, severity and recommendations."
    }
}

/// Chooses the review agent and model, then opens it in a new terminal of the selected project.
struct PullRequestReviewSheet: View {
    let pr: PullRequestSummary
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentKind = .claude
    @State private var model = ""
    @State private var headSHA: String?
    @State private var error: String?

    private var agents: [AgentKind] {
        AgentRegistry.builtin.enabledKinds(environment.preferences?.document.enabledAgents).filter { $0 != .shell }
    }

    private var project: Project? {
        guard let document = environment.workspace?.document else { return nil }
        return document.workspace.selectedProjectID.flatMap(document.project)
            ?? document.recentProjectIDs(limit: 1).first.flatMap(document.project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.space(.l)) {
            Text("pullRequests.reviewTitle").font(.headline)
            Text(verbatim: "\(pr.repo) #\(pr.number) · \(pr.title)")
                .foregroundStyle(theme[.textSecondary])
                .lineLimit(2)
            Form {
                Picker("pullRequests.reviewAgent", selection: $agent) {
                    ForEach(agents, id: \.self) { Text(verbatim: AgentLabels.name(for: $0.rawValue)).tag($0) }
                }
                TextField("pullRequests.reviewModel", text: $model, prompt: Text("pullRequests.reviewModel.placeholder"))
                LabeledContent("pullRequests.headSHA") {
                    if let headSHA {
                        Text(verbatim: String(headSHA.prefix(12))).font(.body.monospaced()).textSelection(.enabled)
                    } else if error == nil {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent("pullRequests.reviewProject") {
                    Text(verbatim: project?.name ?? "—")
                }
            }
            .formStyle(.grouped)
            if let error {
                Text(error).foregroundStyle(theme[.statusStopped]).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("pullRequests.cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("pullRequests.startReview") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(headSHA == nil || project == nil || agents.isEmpty)
            }
        }
        .padding(metrics.space(.xl))
        .frame(width: metrics.size(480))
        .onAppear {
            let state = PullRequestReviewState.shared
            agent = agents.contains(state.agent) ? state.agent : (agents.first ?? .claude)
            model = state.model
        }
        .task { await loadHead() }
    }

    /// Reads the current head SHA from GitHub so the review and merge target the same commit.
    private func loadHead() async {
        do {
            let details = try await GitHubPullRequests().details(for: pr)
            if let sha = details.headSHA, !sha.isEmpty { headSHA = sha } else { error = String(localized: "pullRequests.noHead") }
        } catch is CancellationError {
        } catch GitHubPullRequestError.commandFailed(_, let stderr) where !stderr.isEmpty {
            error = stderr
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func start() {
        guard let headSHA, let project, let workspace = environment.workspace else { return }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = PaneTab(agent: agent.rawValue,
                          title: String(format: String(localized: "pullRequests.reviewPaneName"), pr.number),
                          extraArguments: trimmedModel.isEmpty ? [] : ["--model", trimmedModel],
                          initialPrompt: PullRequestReviewState.prompt(for: pr, headSHA: headSHA))
        workspace.update {
            $0.openInTab(project.id)
            $0.addPane(to: project.id, tab: tab)
        }
        let state = PullRequestReviewState.shared
        state.record(pr, headSHA: headSHA)
        state.agent = agent
        state.model = trimmedModel
        dismiss()
    }
}

/// Confirms and runs the squash merge guarded by the reviewed head SHA.
struct PullRequestMergeSheet: View {
    let pr: PullRequestSummary
    let headSHA: String
    var onMerged: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var merged = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.space(.l)) {
            Text("pullRequests.mergeTitle").font(.headline)
            Text(verbatim: "\(pr.repo) #\(pr.number) · \(pr.title)")
                .foregroundStyle(theme[.textSecondary])
                .lineLimit(2)
            LabeledContent("pullRequests.headSHA") {
                Text(verbatim: headSHA).font(.body.monospaced()).textSelection(.enabled)
            }
            Text("pullRequests.mergeHint").font(.caption).foregroundStyle(theme[.textSecondary])
            if merged {
                Label("pullRequests.merged", systemImage: "checkmark.circle.fill").foregroundStyle(theme[.statusActive])
            }
            if let error {
                VStack(alignment: .leading, spacing: metrics.space(.s)) {
                    Text(error).foregroundStyle(theme[.statusStopped]).textSelection(.enabled)
                    Text("pullRequests.reviewAgain").font(.caption).foregroundStyle(theme[.textSecondary])
                }
            }
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                if merged {
                    Button("pullRequests.done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("pullRequests.cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("pullRequests.squashMerge") { Task { await merge() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running)
                }
            }
        }
        .padding(metrics.space(.xl))
        .frame(width: metrics.size(480))
    }

    private func merge() async {
        running = true
        error = nil
        defer { running = false }
        do {
            try await GitHubPullRequests().squashMerge(pr, headSHA: headSHA)
            merged = true
            PullRequestReviewState.shared.forget(pr)
            onMerged()
        } catch GitHubPullRequestError.commandFailed(_, let stderr) where !stderr.isEmpty {
            error = stderr
        } catch {
            self.error = error.localizedDescription
        }
    }
}
