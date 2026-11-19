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

/// What `guardrails approve <PR>` or `guardrails on <PR>` is about to do to one PR.
public struct PullRequestPlan: Codable, Sendable, Equatable {
    public let repo: String
    public let pr: Int
    public let url: String
    public let title: String
    public let sha: String
    public let files: [PlannedFile]
    /// True when `approve` merges the owner's own PR (review mode: GitHub does not take their review, their
    /// admin bypass skips the review but not the checks). Absent in `on` plans.
    public let merge: Bool?
    /// In `approve`: the owner's own PR goes into the repository's merge queue instead of merging at once. In
    /// `on`: the default branch will require the merge queue. Older CLIs leave it out.
    public let mergeQueue: Bool?

    public init(
        repo: String, pr: Int, url: String, title: String, sha: String, files: [PlannedFile], merge: Bool?,
        mergeQueue: Bool?
    ) {
        self.repo = repo
        self.pr = pr
        self.url = url
        self.title = title
        self.sha = sha
        self.files = files
        self.merge = merge
        self.mergeQueue = mergeQueue
    }

    public var shortSHA: String { String(sha.prefix(7)) }
    public var isOwnMerge: Bool { merge == true }
    /// The owner's own PR is added to the merge queue rather than merged now.
    public var isOwnQueueEntry: Bool { isOwnMerge && mergeQueue == true }
    public var hasWorkflowChanges: Bool { files.contains(where: \.isWorkflow) }
    /// Workflow or human-owned files change: the owner opens the diff before the app lets them confirm.
    public var needsDiffReview: Bool { files.contains { $0.isWorkflow || $0.isHumanOwned } }
}

/// What `guardrails on <owner/repo>` is about to enforce.
public struct RepoPlan: Codable, Sendable, Equatable {
    public let repo: String
    public let branch: String
    /// The default branch will require GitHub's merge queue. Older CLIs leave it out.
    public let mergeQueue: Bool?

    public init(repo: String, branch: String, mergeQueue: Bool?) {
        self.repo = repo
        self.branch = branch
        self.mergeQueue = mergeQueue
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
}

public enum ConfirmStep: String, Codable, Sendable {
    case commit
    case workflows
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
