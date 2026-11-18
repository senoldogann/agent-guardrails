import GuardrailsCore
import SwiftUI

/// A pull request inside the app: what it changes, its checks, history and diff, and what the owner can do
/// with it. Approvals still go through a Review tab.
struct PullRequestPage: View {
    let pullRequest: PullRequestModel
    let model: AppModel

    private var ref: PullRequestRef { pullRequest.ref }

    var body: some View {
        VStack(spacing: 0) {
            switch pullRequest.detail {
            case .loading:
                ProgressView("Loading #\(ref.number) from GitHub…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                StatusPanel(symbol: "exclamationmark.triangle", title: "Could not load #\(ref.number)", message: message)
                    .padding(Metrics.windowPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .loaded(let pr):
                PullRequestHeader(pr: pr, ref: ref, pullRequest: pullRequest, model: model)
                Divider()
                PullRequestTabContent(pr: pr, ref: ref, pullRequest: pullRequest, model: model, tab: pullRequest.tab)
            }
        }
        .task {
            // Loaded once when the tab opens; Refresh (⌘R in the page) loads it again.
            if case .loading = pullRequest.detail { await pullRequest.load() }
        }
    }
}

enum PullRequestTab: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case timeline = "Timeline"
    case code = "Code"

    var id: String { rawValue }
}

/// Title, author, branches, size, state, the main action and the tab picker.
struct PullRequestHeader: View {
    let pr: PullRequestDetail
    let ref: PullRequestRef
    let pullRequest: PullRequestModel
    let model: AppModel

    var body: some View {
        @Bindable var pullRequest = pullRequest
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(displaySafe(pr.title))
                    .font(.system(size: 18, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if pullRequest.isLoading || pullRequest.running != nil {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await pullRequest.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Load the pull request again")
                .accessibilityLabel("Load the pull request again")
                PullRequestMenu(pr: pr, ref: ref, pullRequest: pullRequest, model: model)
            }
            HStack(spacing: 8) {
                PullRequestStateChip(pr: pr)
                Text("#\(pr.number) · \(displaySafe(pr.author?.login ?? "")) · updated \(relativeTime(pr.updatedAt))")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("\(pr.baseRefName) ← \(displaySafe(pr.headRefName))")
                    .font(.mono)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                DiffStatsLabel(diff: .loaded(DiffStats(additions: pr.additions, deletions: pr.deletions, changedFiles: pr.changedFiles)))
            }
            if let running = pullRequest.running {
                Text(running).font(.caption).foregroundStyle(Palette.textSecondary)
            }
            if let problem = pullRequest.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Palette.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Picker("View", selection: $pullRequest.tab) {
                    ForEach(PullRequestTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 8)
                ChecksSummary(checks: pr.checks)
                PullRequestMainAction(pr: pr, ref: ref, pullRequest: pullRequest, model: model)
            }
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.vertical, 16)
    }
}

struct PullRequestStateChip: View {
    let pr: PullRequestDetail

    var body: some View {
        let (title, color) = stateLook
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Palette.surfaceMuted))
        .overlay(Capsule().strokeBorder(Palette.hairline))
    }

    private var stateLook: (String, Color) {
        switch pr.state {
        case "MERGED": ("Merged", Palette.success)
        case "CLOSED": ("Closed", Palette.danger)
        default:
            if pr.isDraft { ("Draft", Palette.textSecondary) }
            else if pr.isApproved { (pr.autoMergeRequest == nil ? "Approved" : "Approved · auto-merge on", Palette.success) }
            else { (pr.autoMergeRequest == nil ? "Open" : "Open · auto-merge on", Palette.warning) }
        }
    }
}

/// "All checks passed", "1 failing", "2 running": the head's checks in a few words.
struct ChecksSummary: View {
    let checks: [RollupEntry]

    var body: some View {
        let failed = checks.filter { $0.outcome == .failed }.count
        let running = checks.filter { $0.outcome == .running }.count
        let (symbol, text, color): (String, String, Color) =
            if checks.isEmpty { ("circle.dashed", "No checks", Palette.textSecondary) }
            else if failed > 0 { ("xmark.circle", "\(failed) failing", Palette.danger) }
            else if running > 0 { ("clock", "\(running) running", Palette.warning) }
            else { ("checkmark.circle", "All checks passed", Palette.success) }
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// The one thing to do next: review an unapproved PR, or merge an approved one GitHub would merge now.
struct PullRequestMainAction: View {
    let pr: PullRequestDetail
    let ref: PullRequestRef
    let pullRequest: PullRequestModel
    let model: AppModel
    @State private var confirmsMerge = false

    var body: some View {
        let actions = availableActions(pr)
        if actions.contains(.merge) {
            Button("Merge…") { confirmsMerge = true }
                .primaryAction()
                .disabled(pullRequest.running != nil)
                .confirmationDialog("Merge #\(pr.number) at \(pr.shortSHA)?", isPresented: $confirmsMerge) {
                    Button("Squash and merge") {
                        Task { await record(await pullRequest.perform(.merge)) }
                    }
                } message: {
                    Text("Squash-merges exactly \(pr.shortSHA) into \(pr.baseRefName) and deletes the branch. GitHub refuses if the PR moved.")
                }
        } else if pr.isOpen, !pr.isDraft, !pr.isApproved {
            Button("Review…") {
                model.openReview(ActionRequest(kind: .approve, target: ref.url, label: displaySafe(pr.title)))
            }
            .primaryAction()
            .disabled(model.snapshot.hasKitInstallAlarm)
            .help(model.snapshot.hasKitInstallAlarm ? "Update the kit first" : "Check the guard and approve exactly this commit")
        }
    }

    private func record(_ entry: ActivityEntry?) async {
        await pullRequestChanged(entry, repo: ref.repo, model: model)
    }
}

/// Everything else the owner can do with the PR.
struct PullRequestMenu: View {
    let pr: PullRequestDetail
    let ref: PullRequestRef
    let pullRequest: PullRequestModel
    let model: AppModel
    @State private var confirmsClose = false

    var body: some View {
        Menu {
            ForEach(availableActions(pr).filter { $0 != .merge && $0 != .close }, id: \.self) { action in
                Button(menuTitle(action)) { run(action) }
            }
            Divider()
            Button("Open on GitHub") { openInBrowser(pr.url) }
            Button("Copy Link") { copyToPasteboard(pr.url) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy PR Number") { copyToPasteboard("#\(pr.number)") }
            Button("Copy Checkout Command") { copyToPasteboard("gh pr checkout \(pr.number) -R \(ref.repo)") }
            if availableActions(pr).contains(.close) {
                Divider()
                Button("Close Pull Request…", role: .destructive) { confirmsClose = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
        .disabled(pullRequest.running != nil)
        .help("More actions")
        .confirmationDialog("Close #\(pr.number) without merging?", isPresented: $confirmsClose) {
            Button("Close Pull Request", role: .destructive) { run(.close) }
        } message: {
            Text("The branch stays; you can reopen it later.")
        }
    }

    private func run(_ action: PullRequestAction) {
        Task { await pullRequestChanged(await pullRequest.perform(action), repo: ref.repo, model: model) }
    }
}

private func menuTitle(_ action: PullRequestAction) -> String {
    switch action {
    case .merge: "Merge…"
    case .enableAutoMerge: "Merge Automatically When Checks Pass"
    case .disableAutoMerge: "Turn Off Auto-Merge"
    case .markReady: "Mark Ready for Review"
    case .convertToDraft: "Convert to Draft"
    case .close: "Close Pull Request…"
    case .reopen: "Reopen Pull Request"
    }
}

/// After the owner changed a PR: log it, and reload the repository's PR list and the inbox.
@MainActor
func pullRequestChanged(_ entry: ActivityEntry?, repo: String, model: AppModel) async {
    guard let entry else { return }
    model.activity.record([entry])
    model.refreshSoon(repo: repo)
    await model.projects?.reloadPullRequests(of: repo)
}
