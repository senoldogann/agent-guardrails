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

/// What makes one repository's merges guarded, from what `guardrails projects --json` establishes about it. Only an
/// enforced repository (`on`: listed on this Mac with its branch ruleset active) shows proved links. An alarm proves
/// nothing either way: it can mean the ruleset is disabled or missing, that GitHub cannot read the repository, or
/// that this Mac's list lost it. So the ruleset link is broken and the rest unknown until the alarm is resolved
/// (Restore, or what the alarm says). A repository a teammate enforces from another Mac is unknown here, not off.
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
    /// A run failed: the approval should wait.
    case problem
    /// Results are still coming in, or could not be read.
    case waiting
    /// Every run reported passed.
    case passed
    /// Nothing failed, but not every run passed: some were skipped or neutral.
    case incomplete
}

/// What the check runs on the commit under review add up to, read once for the rail and its summary. The guard is the
/// run named guard; every other run is a check. A neutral or skipped run is neither a pass nor a failure, so "passed"
/// is said only when every run passed.
public struct ChecksReading: Sendable, Equatable {
    public let guardLink: ChainLink
    public let checksLink: ChainLink
    public let summary: String
    public let tone: ChecksTone

    public init(_ evidence: ChecksEvidence) {
        let runs: [CheckRun]
        switch evidence {
        case .loading:
            guardLink = ChainLink(kind: .guardRun, title: "Guard", detail: "loading", state: .unknown)
            checksLink = ChainLink(kind: .checks, title: "Checks", detail: "loading", state: .unknown)
            summary = "Loading the checks from GitHub…"
            tone = .waiting
            return
        case .unavailable:
            guardLink = ChainLink(kind: .guardRun, title: "Guard", detail: "not read", state: .unknown)
            checksLink = ChainLink(kind: .checks, title: "Checks", detail: "not read", state: .unknown)
            summary = "The checks could not be read from GitHub; load them again under Checks."
            tone = .waiting
            return
        case .loaded(let loaded):
            runs = loaded
        }

        let guardRun = runs.first { $0.name.lowercased().hasPrefix("guard") }
        guardLink = ChainLink(
            kind: .guardRun, title: "Guard",
            detail: guardRun.map { run in
                run.name.lowercased() == "guard" ? Self.word(run) : "\(run.name) · \(Self.word(run))"
            } ?? "not run yet",
            state: guardRun.map(Self.state(of:)) ?? .pending)

        let checks = runs.filter { $0.id != guardRun?.id }
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

        if let broken = [guardLink, checksLink].first(where: { $0.state == .failed }) {
            summary = "\(broken.title) \(broken.detail): fix it before approving."
            tone = .problem
        } else if [guardLink, checksLink].contains(where: { $0.state == .now }) {
            summary = "Checks are still running on this commit."
            tone = .waiting
        } else if runs.isEmpty {
            summary = "No checks reported for this commit yet."
            tone = .waiting
        } else if guardRun == nil {
            summary = "The guard has not reported on this commit yet."
            tone = .waiting
        } else if checks.isEmpty {
            summary = "Only the guard has reported on this commit so far."
            tone = .waiting
        } else if runs.allSatisfy({ $0.outcome == .passed }) {
            summary = "Every check reported on this commit passed."
            tone = .passed
        } else {
            summary = "No check failed on this commit, but not all passed: \(Self.tally(runs))."
            tone = .incomplete
        }
    }

    /// "3 passed, 1 skipped, 1 neutral": the finished runs by result, in that order, leaving out the zeros.
    static func tally(_ runs: [CheckRun]) -> String {
        let words = runs.filter { $0.outcome != .running && $0.outcome != .failed }.map(word)
        return ["passed", "skipped", "neutral"]
            .map { result in (result, words.filter { $0 == result }.count) }
            .filter { $0.1 > 0 }
            .map { "\($0.1) \($0.0)" }
            .joined(separator: ", ")
    }

    static func state(of run: CheckRun) -> ChainLink.State {
        switch run.outcome {
        case .passed: .done
        case .failed: .failed
        case .running: .now
        case .skipped: .pending
        }
    }

    /// The run's result in a word: a neutral run is not a skipped one.
    public static func word(_ run: CheckRun) -> String {
        switch run.outcome {
        case .passed: "passed"
        case .failed: "failed"
        case .running: "running"
        case .skipped: run.conclusion == "neutral" ? "neutral" : "skipped"
        }
    }
}

/// The chain a pull request passes, from the CLI's plan, GitHub's check runs and where the owner's action stands:
/// spec (when the PR carries one), guard, checks, approval, merge. The approval and the merge follow the action: `on`
/// merges the bootstrap PR right after the confirmation; in review mode the owner's own PR merges at once, or goes into
/// the merge queue; any other approval leaves the merge to GitHub's auto-merge or a person. After a failed run the app
/// cannot tell what the CLI did before it stopped, so neither link claims anything. Arguments: the plan (`approve` or
/// `turnOn`; any other plan has no chain), the spec's ticket when the PR carries a loaded spec, the checks, and the
/// action's progress.
public func pullRequestChain(plan: Plan, specTicket: String?, checks: ChecksReading, progress: ActionProgress) -> Chain {
    guard let pr = plan.pullRequest else { return Chain(links: [], missing: nil) }
    let mergesNow: Bool
    if case .turnOn = plan { mergesNow = true } else { mergesNow = pr.isOwnMerge && !pr.isOwnQueueEntry }
    let queues: Bool
    if case .approve = plan { queues = pr.isOwnQueueEntry } else { queues = false }

    let approval: ChainLink
    let merge: ChainLink
    switch progress {
    case .preparing, .awaiting, .working, .cancelled:
        approval = ChainLink(
            kind: .approval, title: "Approval",
            detail: progress == .working ? "confirmed, under way" : progress == .cancelled ? "cancelled" : "this commit",
            state: progress == .cancelled ? .pending : .now)
        merge = ChainLink(
            kind: .merge, title: "Merge",
            detail: mergesNow ? "right after you confirm" : queues ? "through the merge queue" : "after your approval",
            state: .pending)
    case .succeeded:
        approval = ChainLink(kind: .approval, title: "Approval", detail: "given for this commit", state: .done)
        merge = ChainLink(
            kind: .merge, title: "Merge",
            detail: mergesNow ? "merged" : queues ? "in the merge queue" : "auto-merge or by hand",
            state: mergesNow ? .done : .pending)
    case .failed:
        approval = ChainLink(kind: .approval, title: "Approval", detail: "stopped: see the log", state: .unknown)
        merge = ChainLink(
            kind: .merge, title: "Merge", detail: mergesNow || queues ? "see the log" : "after your approval",
            state: mergesNow || queues ? .unknown : .pending)
    }

    var links: [ChainLink] = []
    if let specTicket {
        links.append(ChainLink(kind: .spec, title: "Spec", detail: "\(specTicket) · in this change", state: .done))
    }
    links += [checks.guardLink, checks.checksLink, approval, merge]

    let missing: String?
    if let broken = [checks.guardLink, checks.checksLink].first(where: { $0.state == .failed }) {
        missing = "\(broken.title.lowercased()) failed"
    } else if checks.guardLink.state != .done || checks.checksLink.state != .done {
        missing = "the checks"
    } else {
        switch progress {
        case .preparing, .awaiting, .working, .cancelled: missing = "your approval"
        case .failed: missing = nil
        case .succeeded: missing = mergesNow ? nil : queues ? "the merge queue" : "the merge"
        }
    }
    return Chain(links: links, missing: missing)
}
