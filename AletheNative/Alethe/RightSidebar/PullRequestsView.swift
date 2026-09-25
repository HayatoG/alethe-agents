import AletheDesign
import AletheGit
import AlethePluginKit
import AletheTodos
import AppKit
import SwiftUI

/// The user's open pull requests via `gh` (P4-14); details (checks, review, draft) load per row.
struct PullRequestsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var phase: Phase = .loading
    @State private var prs: [PullRequestSummary] = []
    @State private var detailed: Set<String> = []
    @State private var reload = 0
    @State private var reviewing: PullRequestSummary?
    @State private var merging: PullRequestSummary?
    private var reviews: PullRequestReviewState { environment.pullRequestReviewState }

    static let tabID = "pullRequests"
    static let tab = SidebarTabContribution(id: tabID, title: "Pull Requests", symbol: "arrow.triangle.pull", side: .right, viewID: tabID)

    private enum Phase: Equatable {
        case loading, ready, missing, signedOut
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("pullRequests.title").font(.headline)
                Spacer()
                if phase == .loading { ProgressView().controlSize(.small) }
                Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("pullRequests.refresh")
                    .disabled(phase == .loading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: reload) { await load() }
        .sheet(item: $reviewing) { PullRequestReviewSheet(pr: $0) }
        .sheet(item: $merging) { pr in
            if let sha = reviews.reviewedHead(pr) {
                PullRequestMergeSheet(pr: pr, headSHA: sha) { reload += 1 }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .missing:
            ContentUnavailableView {
                Label("pullRequests.missing", systemImage: "terminal")
            } description: {
                hint("pullRequests.missing.hint", command: "brew install gh")
            }
        case .signedOut:
            ContentUnavailableView {
                Label("pullRequests.signedOut", systemImage: "person.crop.circle.badge.xmark")
            } description: {
                hint("pullRequests.signedOut.hint", command: "gh auth login")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("pullRequests.failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).foregroundStyle(theme[.statusStopped])
            }
        case .loading where prs.isEmpty:
            Color.clear
        case .loading, .ready:
            if prs.isEmpty {
                ContentUnavailableView("pullRequests.empty", systemImage: "arrow.triangle.pull")
            } else {
                List(prs) { pr in
                    row(pr)
                        .task(id: pr.id) { await loadDetails(pr) }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func hint(_ key: LocalizedStringKey, command: String) -> some View {
        VStack(spacing: 6) {
            Text(key)
            Text(verbatim: command)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
    }

    private func row(_ pr: PullRequestSummary) -> some View {
        Button {
            if let url = pr.browserURL { NSWorkspace.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: "\(pr.repo) #\(pr.number)")
                        .font(.caption)
                        .foregroundStyle(theme[.textSecondary])
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    badges(pr)
                }
                Text(pr.title).lineLimit(2)
                HStack(spacing: 4) {
                    Text(verbatim: pr.author)
                    if let updated = pr.updatedAt {
                        Text(verbatim: "·")
                        Text(updated, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(theme[.textSecondary])
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pr.browserURL?.absoluteString ?? "")
        .contextMenu {
            Button("pullRequests.open") { if let url = pr.browserURL { NSWorkspace.shared.open(url) } }
                .disabled(pr.browserURL == nil)
            Button("pullRequests.copyURL") {
                guard let url = pr.browserURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            .disabled(pr.browserURL == nil)
            Button("pullRequests.sendToTodo") {
                guard let url = pr.browserURL else { return }
                _ = TodosPlugin.activeStore?.addPullRequest(number: pr.number, title: pr.title, url: url)
            }
            .disabled(TodosPlugin.activeStore == nil || pr.browserURL == nil)
            Divider()
            Button("pullRequests.reviewWithAgent") { reviewing = pr }
            Button("pullRequests.squashMergeMenu") { merging = pr }
                .disabled(reviews.reviewedHead(pr) == nil)
        }
    }

    @ViewBuilder
    private func badges(_ pr: PullRequestSummary) -> some View {
        if pr.isDraft {
            Text("pullRequests.draft")
                .font(.caption2)
                .foregroundStyle(theme[.statusDisabled])
        }
        switch pr.reviewDecision {
        case .approved:
            Image(systemName: "checkmark.seal").foregroundStyle(theme[.statusActive]).help("pullRequests.review.approved")
        case .changesRequested:
            Image(systemName: "exclamationmark.bubble").foregroundStyle(theme[.statusStopped]).help("pullRequests.review.changes")
        case .reviewRequired:
            Image(systemName: "eye").foregroundStyle(theme[.statusWaiting]).help("pullRequests.review.required")
        default:
            EmptyView()
        }
        switch pr.checks {
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme[.statusActive]).help("pullRequests.checks.success")
        case .failure:
            Image(systemName: "xmark.circle.fill").foregroundStyle(theme[.statusStopped]).help("pullRequests.checks.failure")
        case .pending:
            Image(systemName: "clock").foregroundStyle(theme[.statusWaiting]).help("pullRequests.checks.pending")
        case .none:
            EmptyView()
        }
    }

    private func load() async {
        phase = .loading
        detailed = []
        let client = GitHubPullRequests()
        do {
            switch try await client.status() {
            case .missing: phase = .missing; prs = []; return
            case .signedOut: phase = .signedOut; prs = []; return
            case .ready: break
            }
            prs = try await client.listMine()
            phase = .ready
        } catch is CancellationError {
        } catch GitHubPullRequestError.ghMissing {
            phase = .missing
        } catch GitHubPullRequestError.signedOut {
            phase = .signedOut
        } catch GitHubPullRequestError.cancelled {
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Fetches one row's details once per load; failures leave the row's summary as is.
    private func loadDetails(_ pr: PullRequestSummary) async {
        guard !detailed.contains(pr.id) else { return }
        detailed.insert(pr.id)
        guard let details = try? await GitHubPullRequests().details(for: pr) else { return }
        if let index = prs.firstIndex(where: { $0.id == pr.id }) {
            prs[index] = prs[index].merging(details)
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case GitHubPullRequestError.commandFailed(_, let stderr) where !stderr.isEmpty: stderr
        case GitHubPullRequestError.parseFailed(let detail): detail
        default: error.localizedDescription
        }
    }
}
