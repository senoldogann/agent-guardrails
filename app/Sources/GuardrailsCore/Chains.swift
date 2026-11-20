import Foundation

/// One link of a chain of gates the app draws as a rail: what the link is, what the evidence says about it, and how
/// far that evidence goes. The rails only draw these; deciding them lives here, where it is tested.
public struct ChainLink: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Proved: the link's own evidence passed.
        case done
        /// Where the owner stands now, or what is under way.
        case now
        /// Broken: something failed and blocks the rest.
        case failed
        /// Not reached yet.
        case pending
        /// Not established either way: the app has no evidence for it, or none it can rely on.
        case unknown
    }

    public enum Kind: String, Sendable {
        case spec
        case guardRun = "guard"
        case checks, approval, merge, kit, ruleset, queue
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    public let state: State

    public init(kind: Kind, title: String, detail: String, state: State) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.state = state
    }
}

/// A chain and the words that end its rail: what is still missing, nil when nothing is.
public struct Chain: Sendable, Equatable {
    public let links: [ChainLink]
    public let missing: String?

    public init(links: [ChainLink], missing: String?) {
        self.links = links
        self.missing = missing
    }

    public func link(_ kind: ChainLink.Kind) -> ChainLink? { links.first { $0.kind == kind } }
}

// MARK: repository

/// The project as the app shows it, everywhere it lists or draws it. `on` only says the repository is listed here and
/// its branch ruleset is active; the inbox reads every kit ruleset (`ruleset_problems`), so an `on` repository with an
/// inbox alarm about it, such as a disabled review ruleset, is shown as an alarm, with the alarm's words as its note.
public func shownProject(_ project: Project, inbox: InboxSnapshot) -> Project {
    let alarms = inbox.alarms(of: project.repo)
    guard project.state == .on, !alarms.isEmpty else { return project }
    let words = alarms.map { alarm in
        let note = alarm.noteBesideRestore
        let prefix = "\(alarm.repo): "
        return note.hasPrefix(prefix) ? String(note.dropFirst(prefix.count)) : note
    }
    return Project(
        repo: project.repo, state: .alarm, note: words.joined(separator: " "), private: project.private,
        fork: project.fork, branch: project.branch, pushed: project.pushed, openPRs: project.openPRs,
        setupURL: project.setupURL, setupTitle: project.setupTitle, mode: project.mode, agentApp: project.agentApp,
        mergeQueue: project.mergeQueue, organization: project.organization)
}

public func shownProjects(_ projects: [Project], inbox: InboxSnapshot) -> [Project] {
    projects.map { shownProject($0, inbox: inbox) }
}

/// What makes one repository's merges guarded, from what the app shows about it (`shownProject`). Only an enforced
/// repository without an alarm shows proved links. An alarm proves nothing either way: it can mean a ruleset is
/// disabled, missing or changed, that GitHub cannot read the repository, or that this Mac's list lost it, so the
/// ruleset link is broken and the rest unknown until the alarm is resolved (Restore, or what the alarm says). A
/// repository a teammate enforces from another Mac is unknown here, not off.
public func repositoryChain(_ project: Project) -> Chain {
    switch project.state {
    case .on:
        var links = [
            ChainLink(kind: .kit, title: "Kit", detail: "installed", state: .done),
            ChainLink(kind: .ruleset, title: "Ruleset", detail: "\(project.branch) · active", state: .done),
        ]
        let missing: String?
        switch project.mode {
        case .review:
            links.append(ChainLink(kind: .approval, title: "Approval", detail: "yours, per commit", state: .done))
            missing = nil
        case .status:
            links.append(ChainLink(kind: .approval, title: "Approval", detail: "status only", state: .pending))
            missing = "your reviews"
        case nil:
            links.append(ChainLink(kind: .approval, title: "Approval", detail: "mode not reported", state: .unknown))
            missing = nil
        }
        if project.organization == true, project.mergeQueue == true {
            links.append(ChainLink(kind: .queue, title: "Merge queue", detail: "on", state: .done))
        }
        return Chain(links: links, missing: missing)
    case .alarm:
        return Chain(
            links: [
                ChainLink(kind: .kit, title: "Kit", detail: "not confirmed", state: .unknown),
                ChainLink(kind: .ruleset, title: "Ruleset", detail: "alarm: not confirmed", state: .failed),
                ChainLink(kind: .approval, title: "Approval", detail: "not confirmed", state: .unknown),
            ],
            missing: "a fix for the alarm")
    case .elsewhere:
        return Chain(
            links: [
                ChainLink(kind: .kit, title: "Kit", detail: "enforced from another Mac", state: .unknown),
                ChainLink(kind: .ruleset, title: "Ruleset", detail: "not checked here", state: .unknown),
            ],
            missing: nil)
    case .ready:
        return Chain(
            links: [
                ChainLink(kind: .kit, title: "Kit", detail: "in the bootstrap PR", state: .pending),
                ChainLink(kind: .ruleset, title: "Ruleset", detail: "\(project.branch) stays open", state: .pending),
            ],
            missing: "turning it on")
    case .off:
        return Chain(
            links: [
                ChainLink(kind: .kit, title: "Kit", detail: "not turned on", state: .pending),
                ChainLink(kind: .ruleset, title: "Ruleset", detail: "\(project.branch) stays open", state: .pending),
            ],
            missing: "turning it on")
    case .noAdmin:
        return Chain(
            links: [
                ChainLink(kind: .kit, title: "Kit", detail: "not turned on", state: .pending),
                ChainLink(kind: .ruleset, title: "Ruleset", detail: "needs admin rights", state: .pending),
            ],
            missing: "admin rights")
    }
}

/// What the repository page draws while the inbox does not confirm an enforced repository: before its first read,
/// after a read that failed (the snapshot is then stale), or when its last read did not list the repository (turned
/// on since). The inbox is what reads every kit ruleset and turns a problem into an alarm (`shownProject`), so
/// without it the ruleset and approval are not confirmed: a disabled review ruleset would still look protected.
/// Every other state is drawn as `repositoryChain` draws it, since the inbox only ever turns an enforced repository
/// into an alarm.
public func unconfirmedRepositoryChain(_ project: Project) -> Chain {
    guard project.state == .on else { return repositoryChain(project) }
    return Chain(
        links: [
            ChainLink(kind: .kit, title: "Kit", detail: "installed", state: .done),
            ChainLink(kind: .ruleset, title: "Ruleset", detail: "\(project.branch) · waiting for the inbox", state: .unknown),
            ChainLink(kind: .approval, title: "Approval", detail: "waiting for the inbox", state: .unknown),
        ],
        missing: nil)
}

// MARK: pull request

/// The check runs on the commit under review, as far as the app could read them.
public enum ChecksEvidence: Sendable, Equatable {
    case loading
    /// GitHub could not be read; the message says why.
    case unavailable(String)
    case loaded([CheckRun])
}

/// Where the owner's action on a pull request stands.
public enum ActionProgress: Sendable, Equatable {
    /// The CLI reads and checks; no confirmation asked yet.
    case preparing
    /// A confirmation waits for the owner (or their Touch ID).
    case awaiting
    /// Confirmed; the CLI approves or merges now.
    case working
    case succeeded
    /// The CLI stopped with an error; what it did before is in its output.
    case failed
    case cancelled
}

/// The tone of the sentence that sums up the checks.
public enum ChecksTone: Sendable, Equatable {
    /// A run failed: the approval should wait, or the owner should look before turning on.
    case problem
    /// Results are still coming in, or could not be read.
    case waiting
    /// Every run reported passed.
    case passed
    /// Nothing failed, but not every run passed: some were skipped or neutral.
    case incomplete
}

/// The check runs on the commit under review, for the rail and its summary, read as the CLI's inbox reads them
/// (`pr_states`). The guard is decided by its runs named exactly "guard": any real failure (cancelled, skipped and
/// neutral are not) wins, because a workflow the PR adds could report a run of that name; otherwise the newest run
/// decides, so a run that a newer one cancelled (the guard's concurrency group does that) is not a failure, and only a
/// newest run that succeeded passes the guard. Every other check is counted by its newest run per name, as GitHub does
/// for a required check after a rerun. One difference from the CLI, which orders runs by start time: here "newest" is
/// the highest run id, since GitHub numbers runs as it creates them, while start times have whole seconds and a queued
/// run has none. A neutral or skipped check is neither a pass nor a failure, so "passed" is said only when every
/// counted run passed.
public struct ChecksReading: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case loading
        case unavailable
        case loaded
    }

    public let source: Source
    /// The run that decides the guard; nil when none was reported or the runs are not loaded.
    public let guardRun: CheckRun?
    /// Every other check, the newest run of each name, ordered by name.
    public let checks: [CheckRun]
    /// Runs a newer run of the same name replaced: listed, but not counted.
    public let replacedIDs: Set<Int>
    public let guardLink: ChainLink
    public let checksLink: ChainLink

    public init(_ evidence: ChecksEvidence) {
        let runs: [CheckRun]
        switch evidence {
        case .loading:
            source = .loading
            guardRun = nil
            checks = []
            replacedIDs = []
            guardLink = ChainLink(kind: .guardRun, title: "Guard", detail: "loading", state: .unknown)
            checksLink = ChainLink(kind: .checks, title: "Checks", detail: "loading", state: .unknown)
            return
        case .unavailable:
            source = .unavailable
            guardRun = nil
            checks = []
            replacedIDs = []
            guardLink = ChainLink(kind: .guardRun, title: "Guard", detail: "not read", state: .unknown)
            checksLink = ChainLink(kind: .checks, title: "Checks", detail: "not read", state: .unknown)
            return
        case .loaded(let loaded):
            source = .loaded
            runs = loaded
        }

        let guardRuns = runs.filter { $0.name == "guard" }
        let decisive =
            guardRuns.first { $0.status == "completed" && !Self.notFailures.contains($0.conclusion ?? "") }
            ?? guardRuns.max { $0.id < $1.id }
        guardRun = decisive
        guardLink = ChainLink(
            kind: .guardRun, title: "Guard", detail: decisive.map(Self.word) ?? "not run yet",
            state: decisive.map { $0.outcome == .passed ? .done : $0.outcome == .running ? .now : .failed } ?? .pending)

        var newest: [String: CheckRun] = [:]
        for run in runs {
            if let kept = newest[run.name], kept.id > run.id { continue }
            newest[run.name] = run
        }
        checks = newest.values.filter { $0.name != "guard" }.sorted { $0.name < $1.name }
        // A guard run that failed for real stays a failure, whatever ran after it: any of them decides the guard.
        replacedIDs = Set(
            runs.filter { run in
                newest[run.name]?.id != run.id
                    && !(run.name == "guard" && run.status == "completed"
                        && !Self.notFailures.contains(run.conclusion ?? ""))
            }.map(\.id))

        let failed = checks.filter { $0.outcome == .failed }.count
        let running = checks.filter { $0.outcome == .running }.count
        let passed = checks.filter { $0.outcome == .passed }.count
        // Failed first, then what still runs: only finished runs say whether the checks passed.
        if checks.isEmpty {
            checksLink = ChainLink(kind: .checks, title: "Checks", detail: "none reported", state: .pending)
        } else if failed > 0 {
            checksLink = ChainLink(kind: .checks, title: "Checks", detail: "\(failed) failing", state: .failed)
        } else if running > 0 {
            checksLink = ChainLink(
                kind: .checks, title: "Checks", detail: "\(running) running, \(passed) passed", state: .now)
        } else if passed == 0 {
            checksLink = ChainLink(
                kind: .checks, title: "Checks", detail: Self.tally(checks) + ", none passed", state: .unknown)
        } else {
            checksLink = ChainLink(kind: .checks, title: "Checks", detail: Self.tally(checks), state: .done)
        }
    }

    /// The guard run and the counted checks.
    public var counted: [CheckRun] { (guardRun.map { [$0] } ?? []) + checks }

    /// Conclusions of a completed guard run that are no failure of the guard itself.
    static let notFailures: Set<String> = ["success", "cancelled", "skipped", "neutral"]

    /// "3 passed, 1 skipped, 1 neutral": the finished runs that did not fail, by result, leaving out the zeros.
    static func tally(_ runs: [CheckRun]) -> String {
        let words = runs.filter { $0.outcome != .running && $0.outcome != .failed }.map(word)
        return ["passed", "skipped", "neutral"]
            .map { result in (result, words.filter { $0 == result }.count) }
            .filter { $0.1 > 0 }
            .map { "\($0.1) \($0.0)" }
            .joined(separator: ", ")
    }

    /// The run's result in a word: a neutral run is not a skipped one, and a cancelled run did not fail a check.
    public static func word(_ run: CheckRun) -> String {
        switch run.outcome {
        case .passed: "passed"
        case .failed: run.conclusion == "cancelled" ? "cancelled" : "failed"
        case .running: "running"
        case .skipped: run.conclusion == "neutral" ? "neutral" : "skipped"
        }
    }
}

/// The sentence under the commit and its tone.
public struct ChecksSentence: Sendable, Equatable {
    public let text: String
    public let tone: ChecksTone
}

/// What the checks add up to for the action at hand. An approval waits for the guard and every check. Turning a
/// repository on merges its bootstrap PR before any ruleset exists, and the guard cannot run on that PR yet (it runs
/// from the default branch, which does not have it), so there the checks inform the owner and a failure is a reason
/// to look first, not a stop. Arguments: the checks, the plan (`approve` or `turnOn`).
public func summarizeChecks(_ reading: ChecksReading, for plan: Plan) -> ChecksSentence {
    switch reading.source {
    case .loading:
        return ChecksSentence(text: "Loading the checks from GitHub…", tone: .waiting)
    case .unavailable:
        return ChecksSentence(
            text: "The checks could not be read from GitHub; load them again under Checks.", tone: .waiting)
    case .loaded:
        break
    }
    let gates = [reading.guardLink, reading.checksLink]
    let runs = reading.counted
    if case .turnOn = plan {
        if let broken = gates.first(where: { $0.state == .failed }) {
            return ChecksSentence(
                text: "\(broken.title) \(broken.detail): turning on merges this PR anyway, so look at it first.",
                tone: .problem)
        }
        if gates.contains(where: { $0.state == .now }) {
            return ChecksSentence(text: "Checks are still running on this commit.", tone: .waiting)
        }
        if reading.checks.isEmpty {
            return ChecksSentence(text: "No checks reported for this commit yet.", tone: .waiting)
        }
    } else {
        if let broken = gates.first(where: { $0.state == .failed }) {
            return ChecksSentence(text: "\(broken.title) \(broken.detail): fix it before approving.", tone: .problem)
        }
        if gates.contains(where: { $0.state == .now }) {
            return ChecksSentence(text: "Checks are still running on this commit.", tone: .waiting)
        }
        if runs.isEmpty {
            return ChecksSentence(text: "No checks reported for this commit yet.", tone: .waiting)
        }
        if reading.guardRun == nil {
            return ChecksSentence(text: "The guard has not reported on this commit yet.", tone: .waiting)
        }
        if reading.checks.isEmpty {
            return ChecksSentence(text: "Only the guard has reported on this commit so far.", tone: .waiting)
        }
    }
    if runs.allSatisfy({ $0.outcome == .passed }) {
        return ChecksSentence(text: "Every check reported on this commit passed.", tone: .passed)
    }
    return ChecksSentence(
        text: "No check failed on this commit, but not all passed: \(ChecksReading.tally(runs)).", tone: .incomplete)
}

/// The chain a pull request passes, from the CLI's plan, GitHub's check runs and where the owner's action stands:
/// spec (when the PR carries one), guard, checks, approval, merge. A bootstrap PR (`turnOn`) has no guard to wait for:
/// the guard runs from the default branch, which does not have it yet, so its link is shown only when a guard run
/// reported, and its checks inform rather than block. The approval and the merge follow the action: `on` merges the
/// bootstrap PR right after the confirmation; in review mode the owner's own PR merges at once, or goes into the merge
/// queue, without any GitHub review; any other approval leaves the merge to GitHub's auto-merge or a person. While the
/// run works, and after it failed, nothing is said to be missing: the run's own output says what happened, and the app
/// cannot tell what a failed run did before it stopped, so neither link claims anything then. After a success only the
/// merge can still be missing, whatever the (possibly older) check results show. Arguments: the plan (`approve` or
/// `turnOn`; any other plan has no chain), the spec's ticket when the PR carries a loaded spec, the checks, and the
/// action's progress.
public func pullRequestChain(plan: Plan, specTicket: String?, checks: ChecksReading, progress: ActionProgress) -> Chain {
    guard let pr = plan.pullRequest else { return Chain(links: [], missing: nil) }
    let turningOn: Bool
    if case .turnOn = plan { turningOn = true } else { turningOn = false }
    let mergesNow = turningOn || (pr.isOwnMerge && !pr.isOwnQueueEntry)
    let queues = !turningOn && pr.isOwnQueueEntry
    let unreviewed = turningOn || pr.isOwnMerge

    let approval: ChainLink
    switch progress {
    case .preparing, .awaiting:
        approval = ChainLink(kind: .approval, title: "Approval", detail: "this commit", state: .now)
    case .working:
        approval = ChainLink(kind: .approval, title: "Approval", detail: "confirmed, under way", state: .now)
    case .succeeded:
        approval = ChainLink(
            kind: .approval, title: "Approval",
            detail: unreviewed ? "confirmed by you, no GitHub review" : "given for this commit", state: .done)
    case .failed:
        approval = ChainLink(kind: .approval, title: "Approval", detail: "stopped: see the log", state: .unknown)
    case .cancelled:
        approval = ChainLink(kind: .approval, title: "Approval", detail: "cancelled", state: .pending)
    }

    let merge: ChainLink
    if !mergesNow && !queues {
        merge = ChainLink(kind: .merge, title: "Merge", detail: "auto-merge or by hand", state: .pending)
    } else {
        switch progress {
        case .preparing, .awaiting, .cancelled:
            merge = ChainLink(
                kind: .merge, title: "Merge",
                detail: mergesNow ? "right after you confirm" : "through the merge queue", state: .pending)
        case .working:
            merge = ChainLink(kind: .merge, title: "Merge", detail: "under way", state: .now)
        case .succeeded:
            merge = ChainLink(
                kind: .merge, title: "Merge", detail: mergesNow ? "merged" : "in the merge queue",
                state: mergesNow ? .done : .pending)
        case .failed:
            merge = ChainLink(kind: .merge, title: "Merge", detail: "see the log", state: .unknown)
        }
    }

    var links: [ChainLink] = []
    if let specTicket {
        links.append(ChainLink(kind: .spec, title: "Spec", detail: "\(specTicket) · in this change", state: .done))
    }
    if !turningOn || checks.guardRun != nil {
        links.append(checks.guardLink)
    }
    links += [checks.checksLink, approval, merge]

    let missing: String?
    switch progress {
    case .working, .failed:
        missing = nil
    case .succeeded:
        missing = mergesNow ? nil : queues ? "the merge queue" : "the merge"
    case .preparing, .awaiting, .cancelled:
        if turningOn {
            missing = "your approval"
        } else if let broken = [checks.guardLink, checks.checksLink].first(where: { $0.state == .failed }) {
            missing = "\(broken.title.lowercased()) failed"
        } else if checks.guardLink.state != .done || checks.checksLink.state != .done {
            missing = "the checks"
        } else {
            missing = "your approval"
        }
    }
    return Chain(links: links, missing: missing)
}
