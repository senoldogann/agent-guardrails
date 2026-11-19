import Foundation

/// A file of a PR with the marker the CLI gave it: "!!" workflow, "!" human-owned, "" written by the agent.
public struct PlannedFile: Codable, Sendable, Hashable {
    public let path: String
    public let marker: String

    public init(path: String, marker: String) {
        self.path = path
        self.marker = marker
    }

    public var isWorkflow: Bool { marker == "!!" }
    public var isHumanOwned: Bool { marker == "!" }
}

/// A file a re-lock of a ticket's spec lock stops or starts covering, read from both versions of the lock.
public struct LockScopeChange: Codable, Sendable, Hashable {
    public let lock: String
    public let path: String
    /// "dropped": the base version locks the file and the head version does not, so the agent could change it
    /// without a new spec lock. "added": the reverse.
    public let change: String

    public init(lock: String, path: String, change: String) {
        self.lock = lock
        self.path = path
        self.change = change
    }

    public var isDropped: Bool { change == "dropped" }
}

/// What `guardrails approve <PR>` or `guardrails on <PR>` is about to do to one PR.
public struct PullRequestPlan: Codable, Sendable, Equatable {
    public let repo: String
    public let pr: Int
    public let url: String
    public let title: String
    /// The head commit the CLI approves or merges, and nothing else.
    public let sha: String
    /// The base commit read together with `sha`: `files` is GitHub's comparison of exactly `base...sha`. Older CLIs
    /// listed the files by PR number and leave it out; the app then refuses to confirm (`confirmationAnswer`).
    public let base: String?
    public let files: [PlannedFile]
    /// True when `approve` merges the owner's own PR (review mode: GitHub does not take their review, their
    /// admin bypass skips the review but not the checks). Absent in `on` plans.
    public let merge: Bool?
    /// In `approve`: the owner's own PR goes into the repository's merge queue instead of merging at once. In
    /// `on`: the default branch will require the merge queue. Older CLIs leave it out.
    public let mergeQueue: Bool?
    /// In `approve` (review mode): the owner pushed the head of a PR they did not open. GitHub takes no review from
    /// the account that pushed last, so `merge` is true and the PR merges through the admin bypass. Older CLIs leave
    /// it out.
    public let ownPush: Bool?
    /// In `approve`: every file a re-lock of a changed spec lock stops or starts covering. Older CLIs leave it out.
    public let lockScope: [LockScopeChange]?
    /// In `on`: the repository is in review mode and the owner asked to switch it to status mode (--status-mode).
    public let leavesReviewMode: Bool?

    public init(
        repo: String, pr: Int, url: String, title: String, sha: String, base: String?, files: [PlannedFile], merge: Bool?,
        mergeQueue: Bool?, ownPush: Bool?, lockScope: [LockScopeChange]?, leavesReviewMode: Bool?
    ) {
        self.repo = repo
        self.pr = pr
        self.url = url
        self.title = title
        self.sha = sha
        self.base = base
        self.files = files
        self.merge = merge
        self.mergeQueue = mergeQueue
        self.ownPush = ownPush
        self.lockScope = lockScope
        self.leavesReviewMode = leavesReviewMode
    }

    public var shortSHA: String { String(sha.prefix(7)) }
    /// The base commit when the plan names a full one: only then do its files describe one fixed diff.
    public var pinnedBase: String? {
        guard let base, base.count == 40, base.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return base
    }
    /// GitHub's diff of exactly the files the plan lists (`base...sha`), which stays the same after a later push.
    public var compareURL: String? {
        pinnedBase.map { "https://github.com/\(repo)/compare/\($0)...\(sha)" }
    }
    public var isOwnMerge: Bool { merge == true }
    /// The owner's own PR is added to the merge queue rather than merged now.
    public var isOwnQueueEntry: Bool { isOwnMerge && mergeQueue == true }
    /// The PR merges through the admin bypass because the owner pushed its head, not because they opened it.
    public var isOwnPush: Bool { isOwnMerge && ownPush == true }
    public var hasWorkflowChanges: Bool { files.contains(where: \.isWorkflow) }
    public var lockScopeChanges: [LockScopeChange] { lockScope ?? [] }
    /// Files a re-lock stops locking: each needs the separate `unlock` confirmation.
    public var droppedLockedFiles: [LockScopeChange] { lockScopeChanges.filter(\.isDropped) }
    public var hasDroppedLockedFiles: Bool { !droppedLockedFiles.isEmpty }
    /// Workflow, human-owned or no longer locked files change: the owner opens the diff before the app lets them confirm.
    public var needsDiffReview: Bool { files.contains { $0.isWorkflow || $0.isHumanOwned } || hasDroppedLockedFiles }
}

/// What `guardrails on <owner/repo>` is about to enforce.
public struct RepoPlan: Codable, Sendable, Equatable {
    public let repo: String
    public let branch: String
    /// The default branch will require GitHub's merge queue. Older CLIs leave it out.
    public let mergeQueue: Bool?
    /// The approval mode `on` applies: "review" or "status". Older CLIs leave it out.
    public let mode: String?
    /// The repository is in review mode and the owner asked to switch it to status mode (--status-mode), which
    /// deletes the review ruleset. Older CLIs leave it out.
    public let leavesReviewMode: Bool?

    public init(repo: String, branch: String, mergeQueue: Bool?, mode: String?, leavesReviewMode: Bool?) {
        self.repo = repo
        self.branch = branch
        self.mergeQueue = mergeQueue
        self.mode = mode
        self.leavesReviewMode = leavesReviewMode
    }

    public var withMergeQueue: Bool { mergeQueue == true }
}

/// What `guardrails off <owner/repo>` is about to remove.
public struct RemovalPlan: Codable, Sendable, Equatable {
    public let repo: String
    public let branch: String
    public let removed: [String]
    public let notes: [String]
}

/// What `guardrails update` is about to do to the kit install: fast-forward it from one commit to another.
public struct UpdatePlan: Codable, Sendable, Equatable {
    public let from: String
    public let to: String
    public let fromVersion: String
    public let toVersion: String
    /// "<short sha> <subject>" per new commit, newest first. Subjects come from the kit repository.
    public let commits: [String]

    public init(from: String, to: String, fromVersion: String, toVersion: String, commits: [String]) {
        self.from = from
        self.to = to
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.commits = commits
    }

    public var shortTo: String { String(to.prefix(7)) }
}

/// The plan event the CLI writes before its first confirmation.
public enum Plan: Sendable, Equatable {
    case approve(PullRequestPlan)
    case turnOn(PullRequestPlan)
    case turnOnRepo(RepoPlan)
    case turnOff(RemovalPlan)
    case update(UpdatePlan)

    /// The repository the plan acts on; "the kit install" for an update.
    public var repo: String {
        switch self {
        case .approve(let plan), .turnOn(let plan): plan.repo
        case .turnOnRepo(let plan): plan.repo
        case .turnOff(let plan): plan.repo
        case .update: "the kit install"
        }
    }

    public var pullRequest: PullRequestPlan? {
        switch self {
        case .approve(let plan), .turnOn(let plan): plan
        case .turnOnRepo, .turnOff, .update: nil
        }
    }

    /// The plan switches a repository from review mode to status mode. Only `guardrails on --status-mode` plans that,
    /// and the app never passes that flag, so a turn-on run that announces it stops (ActionModel).
    public var leavesReviewMode: Bool {
        switch self {
        case .turnOn(let plan): plan.leavesReviewMode == true
        case .turnOnRepo(let plan): plan.leavesReviewMode == true
        case .approve, .turnOff, .update: false
        }
    }
}

public enum ConfirmStep: String, Codable, Sendable {
    case commit
    case workflows
    /// A re-lock stops locking files; announced in the plan's `lockScope`.
    case unlock
    case repo
}

/// The CLI is about to read a typed confirmation and expects exactly `expect`.
public struct ConfirmRequest: Codable, Sendable, Equatable {
    public let step: ConfirmStep
    public let expect: String

    public init(step: ConfirmStep, expect: String) {
        self.step = step
        self.expect = expect
    }
}

public enum CLIEvent: Sendable, Equatable {
    case plan(Plan)
    case confirm(ConfirmRequest)
}

public struct EventParseError: Error, CustomStringConvertible {
    public let line: String
    public let reason: String

    public var description: String { "guardrails sent an event the app does not understand (\(reason)): \(line)" }
}

private struct EventHeader: Decodable {
    let event: String
    let action: String?
}

/// Parses one line the CLI wrote to GUARDRAILS_EVENTS_FD.
public func parseEvent(_ line: String) throws -> CLIEvent {
    let data = Data(line.utf8)
    let decoder = JSONDecoder()
    do {
        let header = try decoder.decode(EventHeader.self, from: data)
        switch (header.event, header.action) {
        case ("confirm", _):
            return .confirm(try decoder.decode(ConfirmRequest.self, from: data))
        case ("plan", "approve"):
            return .plan(.approve(try decoder.decode(PullRequestPlan.self, from: data)))
        case ("plan", "on"):
            return .plan(.turnOn(try decoder.decode(PullRequestPlan.self, from: data)))
        case ("plan", "on-repo"):
            return .plan(.turnOnRepo(try decoder.decode(RepoPlan.self, from: data)))
        case ("plan", "off"):
            return .plan(.turnOff(try decoder.decode(RemovalPlan.self, from: data)))
        case ("plan", "update"):
            return .plan(.update(try decoder.decode(UpdatePlan.self, from: data)))
        default:
            throw EventParseError(line: line, reason: "unknown event \(header.event) \(header.action ?? "")")
        }
    } catch let error as EventParseError {
        throw error
    } catch {
        throw EventParseError(line: line, reason: String(describing: error))
    }
}
