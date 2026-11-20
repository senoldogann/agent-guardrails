import Foundation

/// Names one pull request; the value a pull request window opens for.
public struct PullRequestRef: Codable, Sendable, Hashable {
    public let repo: String
    public let number: Int

    public init(repo: String, number: Int) {
        self.repo = repo
        self.number = number
    }

    public var url: String { "https://github.com/\(repo)/pull/\(number)" }
}

/// A GitHub user or App as `gh pr view --json` names it (`app/<slug>` for an App's bot).
public struct GitHubActor: Codable, Sendable, Hashable {
    public let login: String

    public init(login: String) {
        self.login = login
    }
}

public struct PullRequestLabel: Codable, Sendable, Hashable {
    public let name: String
}

public struct PullRequestComment: Codable, Sendable, Hashable {
    public let author: GitHubActor?
    public let body: String
    public let createdAt: String
    public let url: String?
}

public struct PullRequestReview: Codable, Sendable, Hashable {
    public struct Commit: Codable, Sendable, Hashable {
        public let oid: String
    }

    public let author: GitHubActor?
    /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED or PENDING.
    public let state: String
    public let body: String
    public let submittedAt: String?
    public let commit: Commit?
}

public struct PullRequestCommit: Codable, Sendable, Hashable {
    public struct Author: Codable, Sendable, Hashable {
        public let login: String?
        public let name: String?
    }

    public let oid: String
    public let messageHeadline: String
    public let committedDate: String
    public let authors: [Author]
}

public struct PullRequestFile: Codable, Sendable, Hashable {
    public let path: String
    public let additions: Int
    public let deletions: Int
}

/// One entry of `statusCheckRollup`: a check run (`name`, `status`, `conclusion`) or a commit status
/// (`context`, `state`).
public struct RollupEntry: Codable, Sendable, Hashable {
    public let typename: String
    public let name: String?
    public let status: String?
    public let conclusion: String?
    public let detailsUrl: String?
    public let context: String?
    public let state: String?
    public let targetUrl: String?
    /// When a check run started (ISO 8601); gh leaves it out for commit statuses.
    public let startedAt: String?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name, status, conclusion, detailsUrl, context, state, targetUrl, startedAt
    }

    public var title: String { name ?? context ?? "check" }
    public var link: String? { detailsUrl ?? targetUrl }

    public var outcome: CheckOutcome {
        if typename == "StatusContext" {
            switch state {
            case "SUCCESS": return .passed
            case "PENDING", "EXPECTED": return .running
            default: return .failed
            }
        }
        guard status == "COMPLETED" else { return .running }
        switch conclusion {
        case "SUCCESS": return .passed
        case "NEUTRAL", "SKIPPED": return .skipped
        default: return .failed
        }
    }
}

/// `gh pr view <n> --json` with the fields in `pullRequestDetailFields`.
public struct PullRequestDetail: Codable, Sendable, Equatable {
    public struct AutoMerge: Codable, Sendable, Equatable {
        public let mergeMethod: String?
    }

    public let number: Int
    public let title: String
    public let body: String
    public let url: String
    /// OPEN, CLOSED or MERGED.
    public let state: String
    public let isDraft: Bool
    public let author: GitHubActor?
    public let baseRefName: String
    public let headRefName: String
    public let headRefOid: String
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    public let createdAt: String
    public let updatedAt: String
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or empty when no review is required.
    public let reviewDecision: String?
    /// CLEAN when GitHub would merge it now; BLOCKED, BEHIND, DIRTY, DRAFT, UNSTABLE, HAS_HOOKS or UNKNOWN.
    public let mergeStateStatus: String
    public let autoMergeRequest: AutoMerge?
    public let labels: [PullRequestLabel]
    public let comments: [PullRequestComment]
    public let reviews: [PullRequestReview]
    public let commits: [PullRequestCommit]
    public let files: [PullRequestFile]
    public let statusCheckRollup: [RollupEntry]

    public var isOpen: Bool { state == "OPEN" }
    public var shortSHA: String { String(headRefOid.prefix(7)) }

    /// The checks of the head commit, failed first, as the owner reads them. A check that ran again with the
    /// same result (a rerun, or `guard` after "ready for review") is listed once; runs that disagree all stay,
    /// because an earlier failure of a check named `guard` can matter (a PR may add a look-alike workflow). A run
    /// that a run of the same name started at or after it cancelled, without being cancelled itself, is left out:
    /// the guard's concurrency group cancels the older run that way, and the CLI's inbox counts no failure for it.
    public var checks: [RollupEntry] {
        let current = statusCheckRollup.filter { entry in
            !(entry.conclusion == "CANCELLED"
                && statusCheckRollup.contains { other in
                    other.title == entry.title && other.conclusion != "CANCELLED"
                        && (other.startedAt ?? "") >= (entry.startedAt ?? "")
                })
        }
        var seen = Set<String>()
        let distinct = current.filter { seen.insert("\($0.title)|\($0.outcome)").inserted }
        return distinct.sorted { ($0.outcome, $0.title) < ($1.outcome, $1.title) }
    }

    /// The owner approved this head: a code owner review in review mode, or the `merge-approval` commit status
    /// in status mode. GitHub dismisses a review and the status names a commit, so a push clears both.
    public var isApproved: Bool {
        reviewDecision == "APPROVED"
            || statusCheckRollup.contains { $0.typename == "StatusContext" && $0.context == "merge-approval" && $0.state == "SUCCESS" }
    }
}

/// The fields `gh pr view --json` must return for `PullRequestDetail`.
public let pullRequestDetailFields = [
    "number", "title", "body", "url", "state", "isDraft", "author", "baseRefName", "headRefName", "headRefOid",
    "additions", "deletions", "changedFiles", "createdAt", "updatedAt", "reviewDecision", "mergeStateStatus",
    "autoMergeRequest", "labels", "comments", "reviews", "commits", "files", "statusCheckRollup",
].joined(separator: ",")

public func parsePullRequestDetail(_ json: String) throws -> PullRequestDetail {
    do {
        return try JSONDecoder().decode(PullRequestDetail.self, from: Data(json.utf8))
    } catch {
        throw JSONLinesError(source: "gh pr view", lineNumber: 1, line: String(json.prefix(300)), reason: String(describing: error))
    }
}

/// What the owner may do to a pull request from the app. Approving is not here: it goes through the Review
/// window and `approve-head`, which check the guard run and pin the commit.
public enum PullRequestAction: Sendable, Equatable {
    /// Squash-merge exactly the approved head, when GitHub's rules already allow it.
    case merge
    case enableAutoMerge
    case disableAutoMerge
    case markReady
    case convertToDraft
    case close
    case reopen
}

/// The actions that fit the pull request's state, in menu order. Merging needs an approval of the current
/// head and GitHub's own "clean" merge state, so the app never offers a merge the rules would refuse or that
/// needs a bypass.
public func availableActions(_ pr: PullRequestDetail) -> [PullRequestAction] {
    guard pr.isOpen else { return pr.state == "CLOSED" ? [.reopen] : [] }
    var actions: [PullRequestAction] = []
    if !pr.isDraft, pr.isApproved, pr.mergeStateStatus == "CLEAN" { actions.append(.merge) }
    if !pr.isDraft { actions.append(pr.autoMergeRequest == nil ? .enableAutoMerge : .disableAutoMerge) }
    actions.append(pr.isDraft ? .markReady : .convertToDraft)
    actions.append(.close)
    return actions
}

/// The gh arguments that perform an action. Merges name the head the owner saw (`--match-head-commit`), so
/// a push in between makes GitHub refuse instead of merging unseen commits. They leave the branch to the
/// repository's delete-on-merge setting, which the kit turns on: gh refuses `--delete-branch` where a merge
/// queue is required, and there `merge` adds the PR to the queue.
public func ghArguments(for action: PullRequestAction, of pr: PullRequestRef, head: String) -> [String] {
    let target = [String(pr.number), "-R", pr.repo]
    switch action {
    case .merge: return ["pr", "merge"] + target + ["--squash", "--match-head-commit", head]
    case .enableAutoMerge: return ["pr", "merge"] + target + ["--auto", "--squash", "--match-head-commit", head]
    case .disableAutoMerge: return ["pr", "merge"] + target + ["--disable-auto"]
    case .markReady: return ["pr", "ready"] + target
    case .convertToDraft: return ["pr", "ready"] + target + ["--undo"]
    case .close: return ["pr", "close"] + target
    case .reopen: return ["pr", "reopen"] + target
    }
}

/// What a merge did, read from the PR's state after gh returned: merged at once, or (still open) taken into the
/// repository's merge queue, which merges it when its group passes.
public func mergeSummary(stateAfter: String) -> String {
    stateAfter == "MERGED" ? "Merged" : "Added to the merge queue"
}

/// What the owner writes on a pull request: a comment, or a review that asks the agent for changes.
public enum PullRequestNote: Sendable, Equatable {
    case comment
    case requestChanges
}

public func ghArguments(for note: PullRequestNote, of pr: PullRequestRef, body: String) -> [String] {
    let target = [String(pr.number), "-R", pr.repo]
    switch note {
    case .comment: return ["pr", "comment"] + target + ["--body", body]
    case .requestChanges: return ["pr", "review"] + target + ["--request-changes", "--body", body]
    }
}

/// One line of a pull request's history.
public struct TimelineEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case commit(sha: String)
        /// The review's state: APPROVED, CHANGES_REQUESTED, COMMENTED or DISMISSED.
        case review(state: String)
        case comment
    }

    public let id: String
    public let date: String
    public let kind: Kind
    public let actor: String
    /// The commit's headline, or the review's or comment's text.
    public let text: String
}

/// Commits, reviews and comments in the order they happened (ISO 8601 dates sort as text).
public func timeline(of pr: PullRequestDetail) -> [TimelineEvent] {
    let commits = pr.commits.map { commit in
        TimelineEvent(
            id: "commit-\(commit.oid)", date: commit.committedDate, kind: .commit(sha: String(commit.oid.prefix(7))),
            actor: commit.authors.first.flatMap { $0.login ?? $0.name } ?? "", text: commit.messageHeadline)
    }
    let reviews = pr.reviews.enumerated().compactMap { index, review -> TimelineEvent? in
        guard let date = review.submittedAt else { return nil }
        return TimelineEvent(
            id: "review-\(index)", date: date, kind: .review(state: review.state), actor: review.author?.login ?? "",
            text: review.body)
    }
    let comments = pr.comments.enumerated().map { index, comment in
        TimelineEvent(
            id: "comment-\(index)", date: comment.createdAt, kind: .comment, actor: comment.author?.login ?? "",
            text: comment.body)
    }
    return (commits + reviews + comments).sorted { ($0.date, $0.id) < ($1.date, $1.id) }
}

/// One file of a unified diff (`gh pr diff`).
public struct FileDiff: Sendable, Equatable, Identifiable {
    public let path: String
    public let lines: [DiffLine]

    public var id: String { path }
    public var additions: Int { lines.filter { $0.kind == .added }.count }
    public var deletions: Int { lines.filter { $0.kind == .removed }.count }
}

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case hunk
        case added
        case removed
        case context
        /// "\ No newline at end of file" and binary-file notes.
        case note
    }

    public let kind: Kind
    public let text: String
}

/// Splits `git diff` output into files; header lines (`index`, `---`, `+++`, modes) are left out.
public func parseUnifiedDiff(_ diff: String) -> [FileDiff] {
    var files: [FileDiff] = []
    var path: String?
    var lines: [DiffLine] = []
    var inHunk = false

    func closeFile() {
        if let path { files.append(FileDiff(path: path, lines: lines)) }
        path = nil
        lines = []
        inHunk = false
    }

    for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        if line.hasPrefix("diff --git ") {
            closeFile()
            path = diffPath(line)
        } else if line.hasPrefix("@@") {
            inHunk = true
            lines.append(DiffLine(kind: .hunk, text: line))
        } else if !inHunk {
            if line.hasPrefix("Binary files ") { lines.append(DiffLine(kind: .note, text: line)) }
        } else if line.hasPrefix("+") {
            lines.append(DiffLine(kind: .added, text: String(line.dropFirst())))
        } else if line.hasPrefix("-") {
            lines.append(DiffLine(kind: .removed, text: String(line.dropFirst())))
        } else if line.hasPrefix("\\") {
            lines.append(DiffLine(kind: .note, text: line))
        } else if line.hasPrefix(" ") {
            lines.append(DiffLine(kind: .context, text: String(line.dropFirst())))
        }
    }
    closeFile()
    return files
}

/// `diff --git a/x b/x` → `x`; for a rename, the new path.
private func diffPath(_ line: String) -> String {
    let rest = line.dropFirst("diff --git ".count)
    if let range = rest.range(of: " b/", options: .backwards) { return String(rest[range.upperBound...]) }
    return String(rest)
}

/// A block of the Markdown GitHub renders in PR bodies and comments, enough to read them: headings, lists,
/// quotes, fenced code and paragraphs. Inline formatting stays in the text for `AttributedString(markdown:)`.
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(marker: String, text: String)
    case quote(String)
    case code(String)
}

public func markdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var code: [String]?
    var previousWasBlank = true

    func closeParagraph() {
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
        paragraph = []
    }

    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        defer { previousWasBlank = trimmed.isEmpty && code == nil }
        if trimmed.hasPrefix("```") {
            if let open = code {
                blocks.append(.code(open.joined(separator: "\n")))
                code = nil
            } else {
                closeParagraph()
                code = []
            }
        } else if code != nil {
            code?.append(line)
        } else if trimmed.isEmpty {
            closeParagraph()
        } else if let heading = trimmed.wholeMatch(of: /(#{1,6})\s+(.*)/) {
            closeParagraph()
            blocks.append(.heading(level: heading.1.count, text: String(heading.2)))
        } else if let item = trimmed.wholeMatch(of: /[-*+]\s+(.*)/) {
            closeParagraph()
            blocks.append(.bullet(String(item.1)))
        } else if let item = trimmed.wholeMatch(of: /(\d+[.)])\s+(.*)/) {
            closeParagraph()
            blocks.append(.numbered(marker: String(item.1), text: String(item.2)))
        } else if let quote = trimmed.wholeMatch(of: />\s?(.*)/) {
            closeParagraph()
            blocks.append(.quote(String(quote.1)))
        } else if paragraph.isEmpty, !previousWasBlank, let last = blocks.last, let item = continuing(last, with: trimmed) {
            // A wrapped list item: the next line belongs to it until a blank line.
            blocks[blocks.count - 1] = item
        } else {
            paragraph.append(trimmed)
        }
    }
    if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
    closeParagraph()
    return blocks
}

private func continuing(_ block: MarkdownBlock, with text: String) -> MarkdownBlock? {
    switch block {
    case .bullet(let item): return .bullet(item + " " + text)
    case .numbered(let marker, let item): return .numbered(marker: marker, text: item + " " + text)
    case .quote(let item): return .quote(item + " " + text)
    default: return nil
    }
}
