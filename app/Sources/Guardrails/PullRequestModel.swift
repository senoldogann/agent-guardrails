import AppKit
import Foundation
import GuardrailsCore
import Observation

/// One pull request as the pull request window shows it: read with the owner's gh, changed with the owner's
/// gh on a click. Approving is not here; it runs `approve-head` in the Review window.
@MainActor
@Observable
final class PullRequestModel {
    let ref: PullRequestRef
    private(set) var detail: Loadable<PullRequestDetail> = .loading
    /// Loaded when the Code tab first opens.
    private(set) var diff: Loadable<[FileDiff]>?
    private(set) var isLoading = false
    /// What runs right now ("Merging…"); the actions wait for it.
    private(set) var running: String?
    /// The last action's error, shown above the tabs until the next action or reload.
    private(set) var problem: String?
    /// Summary, Timeline or Code: kept with the model, so it survives switching tabs of the main window.
    var tab = PullRequestTab.summary

    init(ref: PullRequestRef) {
        self.ref = ref
    }

    func load() async {
        guard isValidRepoName(ref.repo) else {
            detail = .failed("\(ref.repo) is not an owner/repo name.")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let json = try await readGitHub(["pr", "view", String(ref.number), "-R", ref.repo, "--json", pullRequestDetailFields])
            detail = .loaded(try parsePullRequestDetail(json))
        } catch {
            detail = .failed(String(describing: error))
        }
        if diff != nil { await loadDiff() }
    }

    func loadDiff() async {
        diff = .loading
        do {
            let text = try await readGitHub(["pr", "diff", String(ref.number), "-R", ref.repo, "--color", "never"])
            diff = .loaded(parseUnifiedDiff(text))
        } catch {
            diff = .failed(String(describing: error))
        }
    }

    /// Runs one action against the head the window shows, then reloads. Returns the activity line to log.
    func perform(_ action: PullRequestAction) async -> ActivityEntry? {
        guard case .loaded(let pr) = detail, running == nil else { return nil }
        let entry = await run(progress: progressText(action), summary: activitySummary(action), pr: pr) {
            ghArguments(for: action, of: ref, head: pr.headRefOid)
        }
        guard action == .merge, let entry, entry.outcome == .succeeded, case .loaded(let after) = detail else { return entry }
        return ActivityEntry(
            date: entry.date, outcome: entry.outcome, summary: mergeSummary(stateAfter: after.state), repo: entry.repo,
            title: entry.title, detail: entry.detail, url: entry.url)
    }

    /// Posts a comment or a changes-requested review. Returns the activity line, or nil when it failed.
    func send(_ note: PullRequestNote, body: String) async -> ActivityEntry? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .loaded(let pr) = detail, running == nil, !text.isEmpty else { return nil }
        let summary = note == .comment ? "Commented" : "Requested changes"
        return await run(progress: note == .comment ? "Commenting…" : "Requesting changes…", summary: summary, pr: pr) {
            ghArguments(for: note, of: ref, body: text)
        }
    }

    private func run(
        progress: String, summary: String, pr: PullRequestDetail, arguments: () -> [String]
    ) async -> ActivityEntry? {
        running = progress
        problem = nil
        defer { running = nil }
        let entry: ActivityEntry
        do {
            try await writeGitHub(arguments())
            entry = ActivityEntry(
                date: Date(), outcome: .succeeded, summary: summary, repo: ref.repo, title: displaySafe(pr.title),
                detail: pr.shortSHA, url: ref.url)
        } catch {
            problem = String(describing: error)
            entry = ActivityEntry(
                date: Date(), outcome: .failed, summary: "\(summary): failed", repo: ref.repo, title: displaySafe(pr.title),
                detail: String(describing: error).split(separator: "\n").last.map(String.init) ?? "", url: ref.url)
        }
        await load()
        return entry
    }
}

private func progressText(_ action: PullRequestAction) -> String {
    switch action {
    case .merge: "Merging…"
    case .enableAutoMerge: "Turning on auto-merge…"
    case .disableAutoMerge: "Turning off auto-merge…"
    case .markReady: "Marking ready for review…"
    case .convertToDraft: "Converting to draft…"
    case .close: "Closing…"
    case .reopen: "Reopening…"
    }
}

private func activitySummary(_ action: PullRequestAction) -> String {
    switch action {
    case .merge: "Merged"
    case .enableAutoMerge: "Turned on auto-merge"
    case .disableAutoMerge: "Turned off auto-merge"
    case .markReady: "Marked ready for review"
    case .convertToDraft: "Converted to draft"
    case .close: "Closed"
    case .reopen: "Reopened"
    }
}

/// Runs a gh command that changes something on GitHub, once: a comment or merge sent twice is not the same
/// as once, so a failure is reported to the owner instead of retried.
func writeGitHub(_ arguments: [String]) async throws {
    let result = try await runCommand(
        command: ["/usr/bin/env", "gh"] + arguments,
        environment: cliEnvironment(inherited: ProcessInfo.processInfo.environment, eventsDescriptor: nil))
    guard result.status == 0 else {
        throw GitHubCommandError(
            arguments: arguments, status: result.status,
            message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
