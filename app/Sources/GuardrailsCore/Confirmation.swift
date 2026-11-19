import Foundation

public enum ConfirmationError: Error, Equatable, CustomStringConvertible {
    case noPlan(step: ConfirmStep)
    case doesNotMatchPlan(step: ConfirmStep, expected: String, planned: String)
    case notExpected(step: ConfirmStep)
    case unpinnedBase
    case leavesReviewMode(repo: String)

    public var description: String {
        switch self {
        case .leavesReviewMode(let repo):
            "guardrails planned to switch \(repo) from review mode to status mode, which the app never asks for; run guardrails on from the Mac that holds the agent App"
        case .noPlan(let step):
            "guardrails asked for the \(step.rawValue) confirmation before it said what it will do"
        case .doesNotMatchPlan(let step, let expected, let planned):
            "guardrails asked to confirm \(expected) for the \(step.rawValue) step, but its plan says \(planned)"
        case .notExpected(let step):
            "guardrails asked for a \(step.rawValue) confirmation this action does not have"
        case .unpinnedBase:
            "guardrails did not name the base commit its file list compares against, so the list may describe another push; update the kit and the app"
        }
    }
}

/// The text the app types for a confirmation, after checking it against the plan the CLI announced.
/// The app never types what a prompt asks for unless the plan shown to the owner says the same.
public func confirmationAnswer(for request: ConfirmRequest, plan: Plan?) throws -> String {
    guard let plan else { throw ConfirmationError.noPlan(step: request.step) }
    // Leaving review mode takes `guardrails on --status-mode` in the owner's own terminal; the app never passes it.
    guard !plan.leavesReviewMode else { throw ConfirmationError.leavesReviewMode(repo: plan.repo) }
    switch (request.step, plan) {
    case (.commit, .approve(let pr)), (.commit, .turnOn(let pr)):
        let isShortSHA = request.expect.count == 7 && request.expect.allSatisfy(\.isHexDigit)
        guard isShortSHA, request.expect == pr.shortSHA else {
            throw ConfirmationError.doesNotMatchPlan(step: .commit, expected: request.expect, planned: pr.shortSHA)
        }
        // The files the owner reviews must be the diff of one base and head; a plan without the base cannot show that.
        guard pr.pinnedBase != nil else { throw ConfirmationError.unpinnedBase }
        return request.expect
    case (.commit, .update(let update)):
        let isShortSHA = request.expect.count == 7 && request.expect.allSatisfy(\.isHexDigit)
        guard isShortSHA, request.expect == update.shortTo else {
            throw ConfirmationError.doesNotMatchPlan(step: .commit, expected: request.expect, planned: update.shortTo)
        }
        return request.expect
    case (.workflows, .approve(let pr)):
        guard pr.hasWorkflowChanges, request.expect == "workflows" else {
            throw ConfirmationError.doesNotMatchPlan(
                step: .workflows, expected: request.expect, planned: pr.hasWorkflowChanges ? "workflows" : "no workflow changes")
        }
        return request.expect
    case (.unlock, .approve(let pr)):
        guard pr.hasDroppedLockedFiles, request.expect == "unlock" else {
            throw ConfirmationError.doesNotMatchPlan(
                step: .unlock, expected: request.expect, planned: pr.hasDroppedLockedFiles ? "unlock" : "no file a spec lock stops locking")
        }
        return request.expect
    case (.repo, .turnOnRepo(let repoPlan)):
        guard request.expect == repoPlan.repo else {
            throw ConfirmationError.doesNotMatchPlan(step: .repo, expected: request.expect, planned: repoPlan.repo)
        }
        return request.expect
    case (.repo, .turnOff(let removal)):
        guard request.expect == removal.repo else {
            throw ConfirmationError.doesNotMatchPlan(step: .repo, expected: request.expect, planned: removal.repo)
        }
        return request.expect
    default:
        throw ConfirmationError.notExpected(step: request.step)
    }
}

/// Whether answering this step is the last one: after it the CLI acts and cancelling could stop it halfway.
public func isFinalConfirmation(_ request: ConfirmRequest, plan: Plan) -> Bool {
    switch (request.step, plan) {
    case (.commit, .approve(let pr)): !pr.hasWorkflowChanges && !pr.hasDroppedLockedFiles
    case (.workflows, .approve(let pr)): !pr.hasDroppedLockedFiles
    default: true
    }
}

/// The reason macOS shows in the Touch ID / password prompt. The system draws it, so it names exactly
/// what the owner approves: repository, PR and commit.
public func ownerCheckReason(for request: ConfirmRequest, plan: Plan) -> String {
    switch (request.step, plan) {
    case (.commit, .approve(let pr)) where pr.isOwnPush && pr.isOwnQueueEntry:
        "add \(pr.repo) PR #\(pr.pr) at commit \(pr.shortSHA), which you pushed last, to the merge queue"
    case (.commit, .approve(let pr)) where pr.isOwnPush:
        "merge \(pr.repo) PR #\(pr.pr) at commit \(pr.shortSHA), which you pushed last"
    case (.commit, .approve(let pr)) where pr.isOwnQueueEntry:
        "add your own \(pr.repo) PR #\(pr.pr) at commit \(pr.shortSHA) to the merge queue"
    case (.commit, .approve(let pr)) where pr.isOwnMerge:
        "merge your own \(pr.repo) PR #\(pr.pr) at commit \(pr.shortSHA)"
    case (.commit, .approve(let pr)):
        "approve \(pr.repo) PR #\(pr.pr) at commit \(pr.shortSHA)"
    case (.commit, .update(let update)):
        "update the kit install to commit \(update.shortTo) (version \(update.toVersion))"
    case (.workflows, .approve(let pr)):
        "confirm you reviewed the workflow changes in \(pr.repo) PR #\(pr.pr)"
    case (.unlock, .approve(let pr)):
        "confirm \(pr.repo) PR #\(pr.pr) stops locking \(pr.droppedLockedFiles.count) spec-locked file(s)"
    case (.commit, .turnOn(let pr)):
        "merge \(pr.repo) PR #\(pr.pr) at commit \(pr.shortSHA) and turn the guardrails on"
    case (_, .turnOnRepo(let repoPlan)) where repoPlan.withMergeQueue:
        "turn the guardrails on for \(repoPlan.repo) with the merge queue"
    case (_, .turnOnRepo(let repoPlan)):
        "turn the guardrails on for \(repoPlan.repo)"
    case (_, .turnOff(let removal)):
        "turn the guardrails off for \(removal.repo) and remove the kit"
    default:
        "confirm a guardrails action on \(plan.repo)"
    }
}
