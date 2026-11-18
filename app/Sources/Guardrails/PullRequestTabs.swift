import GuardrailsCore
import SwiftUI

struct PullRequestTabContent: View {
    let pr: PullRequestDetail
    let ref: PullRequestRef
    let pullRequest: PullRequestModel
    let model: AppModel
    let tab: PullRequestTab

    var body: some View {
        switch tab {
        case .summary:
            ScrollView {
                PullRequestSummary(pr: pr, ref: ref, pullRequest: pullRequest, model: model)
                    .padding(Metrics.windowPadding)
            }
        case .timeline:
            ScrollView {
                PullRequestTimeline(events: timeline(of: pr)).padding(Metrics.windowPadding)
            }
        case .code:
            PullRequestCode(pullRequest: pullRequest)
        }
    }
}

/// Description, checks, comments and the composer.
struct PullRequestSummary: View {
    let pr: PullRequestDetail
    let ref: PullRequestRef
    let pullRequest: PullRequestModel
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Description")
                Card {
                    if pr.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description.").font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                    } else {
                        MarkdownView(text: pr.body)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SectionLabel(text: "Checks")
                    SHABadge(sha: pr.shortSHA)
                }
                Card {
                    if pr.checks.isEmpty {
                        Text("No checks reported on this commit yet.").font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(pr.checks, id: \.self) { RollupRow(entry: $0) }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: pr.comments.isEmpty ? "Comments" : "Comments (\(pr.comments.count))")
                ForEach(Array(pr.comments.enumerated()), id: \.offset) { _, comment in
                    CommentCard(author: comment.author?.login ?? "", date: comment.createdAt, text: comment.body)
                }
                if pr.isOpen {
                    Composer(pullRequest: pullRequest, repo: ref.repo, model: model)
                }
            }
        }
        .frame(maxWidth: pageWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

struct RollupRow: View {
    let entry: RollupEntry

    var body: some View {
        HStack(spacing: 10) {
            CheckSymbol(outcome: entry.outcome)
            Text(displaySafe(entry.title)).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            Text(outcomeWord(entry.outcome)).font(.caption).foregroundStyle(Palette.textSecondary)
            if let link = entry.link {
                Button {
                    openInBrowser(link)
                } label: {
                    OcticonImage(icon: .linkExternal, size: 14)
                }
                .buttonStyle(.borderless)
                .help("Open the check on GitHub")
                .accessibilityLabel("Open \(displaySafe(entry.title)) on GitHub")
            }
        }
    }
}

private func outcomeWord(_ outcome: CheckOutcome) -> String {
    switch outcome {
    case .failed: "Failed"
    case .running: "Running"
    case .passed: "Passed"
    case .skipped: "Skipped"
    }
}

struct CommentCard: View {
    let author: String
    let date: String
    let text: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(displaySafe(author)).font(.system(size: 12, weight: .semibold))
                    Text(relativeTime(date)).font(.caption).foregroundStyle(Palette.textSecondary)
                }
                MarkdownView(text: text)
            }
        }
    }
}

/// Writes a comment, or a review that asks the agent for changes.
struct Composer: View {
    let pullRequest: PullRequestModel
    let repo: String
    let model: AppModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write a comment for the agent…")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 80)
                .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surfaceMuted))
                .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.hairline))
                .accessibilityLabel("Comment")
            HStack {
                Text("Markdown works. The agent reads comments on its next run.")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 8)
                Button("Request Changes") { send(.requestChanges) }
                    .secondaryAction()
                    .help("A review that tells the agent what to change; GitHub does not allow it on your own PR")
                Button("Comment") { send(.comment) }
                    .primaryAction()
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pullRequest.running != nil)
        }
    }

    private func send(_ note: PullRequestNote) {
        let body = text
        Task {
            let entry = await pullRequest.send(note, body: body)
            if entry?.outcome == .succeeded { text = "" }
            await pullRequestChanged(entry, repo: repo, model: model)
        }
    }
}

struct PullRequestTimeline: View {
    let events: [TimelineEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(events) { event in
                TimelineRow(event: event)
            }
        }
        .frame(maxWidth: pageWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

struct TimelineRow: View {
    let event: TimelineEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OcticonImage(icon: symbol, size: 14)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.surfaceMuted))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displaySafe(event.actor)).font(.system(size: 12, weight: .semibold))
                    Text(verb).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    Text(relativeTime(event.date)).font(.caption).foregroundStyle(Palette.textSecondary)
                }
                if case .commit(let sha) = event.kind {
                    HStack(spacing: 6) {
                        Text(sha).font(.mono).foregroundStyle(Palette.textSecondary)
                        Text(displaySafe(event.text)).font(.system(size: 13)).lineLimit(2)
                    }
                } else if !event.text.isEmpty {
                    MarkdownView(text: event.text)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var symbol: Octicon {
        switch event.kind {
        case .commit: .gitCommit
        case .review(let state) where state == "APPROVED": .check
        case .review(let state) where state == "CHANGES_REQUESTED": .comment
        case .review(let state) where state == "DISMISSED": .dash
        case .review: .comment
        case .comment: .comment
        }
    }

    private var color: Color {
        switch event.kind {
        case .review(let state) where state == "APPROVED": Palette.success
        case .review(let state) where state == "CHANGES_REQUESTED": Palette.warning
        default: Palette.textSecondary
        }
    }

    private var verb: String {
        switch event.kind {
        case .commit: "pushed"
        case .review(let state) where state == "APPROVED": "approved"
        case .review(let state) where state == "CHANGES_REQUESTED": "requested changes"
        case .review(let state) where state == "DISMISSED": "approved an earlier commit (dismissed by a later push)"
        case .review: "reviewed"
        case .comment: "commented"
        }
    }
}

/// The diff, file by file; long files start closed.
struct PullRequestCode: View {
    let pullRequest: PullRequestModel

    var body: some View {
        Group {
            switch pullRequest.diff {
            case nil, .loading:
                ProgressView("Loading the diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                StatusPanel(symbol: .alert, title: "Could not load the diff", message: message)
                    .padding(Metrics.windowPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .loaded(let files):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(files) { FileDiffCard(file: $0) }
                    }
                    .padding(Metrics.windowPadding)
                }
            }
        }
        .task {
            if pullRequest.diff == nil { await pullRequest.loadDiff() }
        }
    }
}

struct FileDiffCard: View {
    let file: FileDiff
    @State private var isExpanded: Bool

    init(file: FileDiff) {
        self.file = file
        _isExpanded = State(initialValue: file.lines.count <= 400)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    OcticonImage(icon: isExpanded ? .chevronDown : .chevronRight, size: 12)
                    Text(displaySafe(file.path)).font(.mono).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("+\(file.additions)").foregroundStyle(Palette.success)
                    Text("−\(file.deletions)").foregroundStyle(Palette.danger)
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Divider()
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surface))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.rowRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.hairline))
    }
}

struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(marker).frame(width: 18).foregroundStyle(Palette.textSecondary)
            Text(displaySafe(line.text).isEmpty ? " " : displaySafe(line.text))
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? Palette.textSecondary : Palette.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.horizontal, 6)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Palette.success.opacity(0.12)
        case .removed: Palette.danger.opacity(0.12)
        case .hunk: Palette.surfaceMuted
        default: .clear
        }
    }
}
