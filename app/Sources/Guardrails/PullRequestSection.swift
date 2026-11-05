import GuardrailsCore
import SwiftUI

/// The open pull requests of an enforced repository, newest first, each with what it waits for.
struct PullRequestSection: View {
    let repo: String
    let projects: ProjectsModel
    let approvalsLocked: Bool
    let open: (ActionRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Pull requests")
                Spacer()
                Button {
                    Task { await projects.reloadPullRequests(of: repo) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .help("Reload pull requests")
            }
            PullRequestList(list: projects.pullRequests[repo], approvalsLocked: approvalsLocked, open: open)
        }
        .task { await projects.loadPullRequests(of: repo) }
    }
}

struct PullRequestList: View {
    let list: ProjectsModel.PullRequestList?
    let approvalsLocked: Bool
    let open: (ActionRequest) -> Void

    var body: some View {
        if let list {
            if list.items.isEmpty {
                Card {
                    Text("No open pull requests.").font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(list.items) { item in
                        PullRequestRow(item: item, approvalsLocked: approvalsLocked, open: open)
                    }
                }
            }
        } else {
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
    let item: PullRequestItem
    let approvalsLocked: Bool
    let open: (ActionRequest) -> Void

    var body: some View {
        HStack(spacing: 12) {
            KindBadge(kind: item.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(displaySafe(item.title)).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text("#\(item.number) · \(item.author) · \(item.note) · updated \(relativeTime(item.updated))")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.kind == .approve {
                Button("Review") {
                    open(ActionRequest(kind: .approve, target: item.url, label: displaySafe(item.title)))
                }
                .buttonStyle(PrimaryPillStyle())
                .disabled(approvalsLocked)
            } else {
                Button {
                    openInBrowser(item.url)
                } label: {
                    GitHubLabel(title: "Open")
                }
                .buttonStyle(SecondaryPillStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.hairline))
    }
}

struct KindBadge: View {
    let kind: PullRequestKind

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(color)
            .frame(width: 22)
            .help(help)
    }

    private var symbol: String {
        switch kind {
        case .approve: "checkmark.seal"
        case .answer: "questionmark.bubble"
        case .wait: "clock"
        case .blocked: "xmark.octagon"
        case .draft: "pencil.line"
        case .approved: "checkmark.seal.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .approve: Palette.textPrimary
        case .answer: Palette.warning
        case .wait, .draft: Palette.textSecondary
        case .blocked: Palette.danger
        case .approved: Palette.success
        }
    }

    private var help: String {
        switch kind {
        case .approve: "Waits for your approval"
        case .answer: "The agent asks you something"
        case .wait: "Checks are running"
        case .blocked: "The guard failed; the agent has to fix it"
        case .draft: "The agent is working on it"
        case .approved: "Approved; merges when checks pass"
        }
    }
}
