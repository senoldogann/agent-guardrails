import GuardrailsCore
import SwiftUI

/// The open pull requests of an enforced repository, newest first, each with what it waits for.
struct PullRequestSection: View {
    let repo: String
    let projects: ProjectsModel
    let approvalsLocked: Bool
    let open: (ActionRequest) -> Void
    let openPullRequest: (PullRequestRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Pull requests")
                Spacer()
                Button {
                    Task { await projects.reloadPullRequests(of: repo) }
                } label: {
                    OcticonImage(icon: .sync, size: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .help("Reload pull requests")
                .accessibilityLabel("Reload pull requests")
            }
            PullRequestList(
                repo: repo, list: projects.pullRequests[repo], error: projects.pullRequestErrors[repo],
                approvalsLocked: approvalsLocked, open: open, openPullRequest: openPullRequest)
        }
        .task { await projects.loadPullRequests(of: repo) }
    }
}

struct PullRequestList: View {
    let repo: String
    let list: ProjectsModel.PullRequestList?
    /// The last load's error; with an older list still shown, it says the list may be out of date.
    let error: String?
    let approvalsLocked: Bool
    let open: (ActionRequest) -> Void
    let openPullRequest: (PullRequestRef) -> Void

    var body: some View {
        if let error {
            Text(list == nil ? error : "Could not reload, showing the last list: \(error)")
                .font(.caption)
                .foregroundStyle(Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if let list {
            if list.items.isEmpty {
                Card {
                    Text("No open pull requests.").font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                }
            } else {
                RowGroup {
                    ForEach(Array(list.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 46) }
                        PullRequestRow(
                            repo: repo, item: item, approvalsLocked: approvalsLocked, open: open,
                            openPullRequest: openPullRequest)
                    }
                }
            }
        } else if error == nil {
            Card {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading pull requests…").font(.system(size: 13))
                }
            }
        }
    }
}

struct PullRequestRow: View {
    let repo: String
    let item: PullRequestItem
    let approvalsLocked: Bool
    let open: (ActionRequest) -> Void
    let openPullRequest: (PullRequestRef) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                openPullRequest(PullRequestRef(repo: repo, number: item.number))
            } label: {
                HStack(spacing: 12) {
                    KindBadge(kind: item.kind)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displaySafe(item.title)).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text("#\(item.number) · \(displaySafe(item.author)) · \(item.note) · updated \(relativeTime(item.updated))")
                            .font(.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open #\(item.number) here: description, checks, history and diff")
            if item.kind == .approve {
                Button("Review") {
                    open(ActionRequest(kind: .approve, target: item.url, label: displaySafe(item.title)))
                }
                .primaryAction()
                .disabled(approvalsLocked)
            } else {
                Button {
                    openInBrowser(item.url)
                } label: {
                    GitHubLabel(title: "Open")
                }
                .secondaryAction()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct KindBadge: View {
    let kind: PullRequestKind

    var body: some View {
        OcticonImage(icon: symbol, size: 14)
            .font(.system(size: 14))
            .foregroundStyle(color)
            .frame(width: 22)
            .help(help)
    }

    private var symbol: Octicon {
        switch kind {
        case .approve: .passkey
        case .queued: .gitMerge
        case .answer: .comment
        case .wait: .clock
        case .blocked: .xCircle
        case .draft: .pullRequestDraft
        case .approved: .check
        }
    }

    private var color: Color {
        switch kind {
        case .approve: Palette.textPrimary
        case .answer: Palette.textSecondary
        case .wait, .draft, .queued: Palette.textSecondary
        case .blocked: Palette.danger
        case .approved: Palette.textSecondary
        }
    }

    private var help: String {
        switch kind {
        case .approve: "Waits for your approval"
        case .answer: "The agent asks you something"
        case .wait: "Checks are running"
        case .blocked: "The guard failed; the agent has to fix it"
        case .draft: "The agent is working on it"
        case .approved: "Approved"
        case .queued: "In the merge queue"
        }
    }
}
