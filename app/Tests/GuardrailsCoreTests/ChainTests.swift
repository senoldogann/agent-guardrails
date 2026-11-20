import Foundation
import Testing

@testable import GuardrailsCore

private func project(_ state: ProjectState, mode: ApprovalMode?, queue: Bool) -> Project {
    Project(
        repo: "acme/shop", state: state, note: "ruleset disabled: restore it or check the audit log", private: true,
        fork: false, branch: "main", pushed: "", openPRs: 0, setupURL: "", setupTitle: "", mode: mode, agentApp: .installed,
        mergeQueue: queue, organization: true)
}

private func run(_ id: Int, _ name: String, _ status: String, _ conclusion: String?) -> CheckRun {
    CheckRun(
        id: id, name: name, status: status, conclusion: conclusion, htmlURL: "https://github.com/acme/shop/runs/\(id)",
        startedAt: nil, completedAt: nil, app: nil)
}

private let guardPassed = run(1, "guard", "completed", "success")

private func pullRequest(merge: Bool?, queue: Bool?) -> PullRequestPlan {
    PullRequestPlan(
        repo: "acme/shop", pr: 7, url: "https://github.com/acme/shop/pull/7", title: "t",
        sha: String(repeating: "a", count: 40), base: String(repeating: "b", count: 40), files: [], merge: merge,
        mergeQueue: queue, ownPush: nil, author: nil, pushedBy: nil, pushedAt: nil, lockScope: nil, leavesReviewMode: nil)
}

private let allPassed = ChecksReading(.loaded([guardPassed, run(2, "checks-node", "completed", "success")]))

@Suite("repository chain")
struct RepositoryChainTests {
    @Test func anEnforcedRepositoryInReviewModeIsProvedThroughout() {
        let chain = repositoryChain(project(.on, mode: .review, queue: true))
        #expect(chain.links.map(\.kind) == [.kit, .ruleset, .approval, .queue])
        #expect(chain.links.allSatisfy { $0.state == .done })
        #expect(chain.link(.ruleset)?.detail == "main · active")
        #expect(chain.missing == nil)
    }

    @Test func anAlarmClaimsNoProtectionAndStaysVisible() {
        // Whatever else the CLI reported, an alarm establishes no rule: the ruleset may be disabled or missing.
        let chain = repositoryChain(project(.alarm, mode: .review, queue: true))
        #expect(!chain.links.contains { $0.state == .done })
        #expect(chain.link(.ruleset)?.state == .failed)
        #expect(chain.link(.approval)?.state == .unknown)
        #expect(chain.link(.queue) == nil)
        #expect(!chain.links.contains { $0.detail.contains("active") || $0.detail.contains("protected") })
        #expect(chain.missing == "a fix for the alarm")
    }

    @Test func unconfiguredRepositoriesStayDistinctFromEnforcedOnes() {
        for state in [ProjectState.off, .ready, .noAdmin] {
            let chain = repositoryChain(project(state, mode: nil, queue: false))
            #expect(chain.links.allSatisfy { $0.state == .pending }, "\(state)")
            #expect(chain.link(.ruleset)?.detail != "main · active", "\(state)")
            #expect(chain.missing != nil, "\(state)")
        }
        #expect(repositoryChain(project(.noAdmin, mode: nil, queue: false)).missing == "admin rights")
    }

    @Test func aTeammatesRepositoryIsUnknownHereNotOff() {
        let chain = repositoryChain(project(.elsewhere, mode: nil, queue: false))
        #expect(chain.links.allSatisfy { $0.state == .unknown })
        #expect(chain.missing == nil)
    }

    @Test func anUnreportedModeIsUnknown() {
        let chain = repositoryChain(project(.on, mode: nil, queue: false))
        #expect(chain.link(.approval)?.state == .unknown)
        #expect(repositoryChain(project(.on, mode: .status, queue: false)).missing == "your reviews")
    }
}

@Suite("checks reading")
struct ChecksReadingTests {
    @Test func everyRunPassed() {
        #expect(allPassed.checksLink.state == .done)
        #expect(allPassed.checksLink.detail == "1 passed")
        #expect(allPassed.summary == "Every check reported on this commit passed.")
        #expect(allPassed.tone == .passed)
    }

    @Test func aFailureWinsOverRunningChecks() {
        let reading = ChecksReading(
            .loaded([
                guardPassed, run(2, "checks-node", "in_progress", nil), run(3, "security", "completed", "failure"),
            ]))
        #expect(reading.checksLink.state == .failed)
        #expect(reading.checksLink.detail == "1 failing")
        #expect(reading.summary == "Checks 1 failing: fix it before approving.")
        #expect(reading.tone == .problem)
    }

    @Test func runningChecksAreNotAnEmptyList() {
        let reading = ChecksReading(
            .loaded([guardPassed, run(2, "checks-node", "in_progress", nil), run(3, "security", "completed", "success")]))
        #expect(reading.checksLink.state == .now)
        #expect(reading.checksLink.detail == "1 running, 1 passed")
        #expect(reading.summary == "Checks are still running on this commit.")
        let guardRunning = ChecksReading(.loaded([run(1, "guard", "queued", nil), run(2, "checks-node", "completed", "success")]))
        #expect(guardRunning.guardLink.state == .now)
        #expect(guardRunning.summary == "Checks are still running on this commit.")
    }

    @Test func skippedAndNeutralRunsAreNotPasses() {
        let reading = ChecksReading(
            .loaded([
                guardPassed, run(2, "checks-node", "completed", "success"), run(3, "security", "completed", "skipped"),
                run(4, "lint", "completed", "neutral"),
            ]))
        #expect(reading.checksLink.state == .done)
        #expect(reading.checksLink.detail == "1 passed, 1 skipped, 1 neutral")
        #expect(reading.summary == "No check failed on this commit, but not all passed: 2 passed, 1 skipped, 1 neutral.")
        #expect(reading.tone == .incomplete)

        let nothingRan = ChecksReading(.loaded([guardPassed, run(2, "checks-node", "completed", "skipped")]))
        #expect(nothingRan.checksLink.state == .unknown)
        #expect(nothingRan.checksLink.detail == "1 skipped, none passed")
        #expect(nothingRan.tone == .incomplete)

        let guardSkipped = ChecksReading(.loaded([run(1, "guard", "completed", "skipped"), run(2, "checks-node", "completed", "success")]))
        #expect(guardSkipped.guardLink.state == .pending)
        #expect(guardSkipped.guardLink.detail == "skipped")
        #expect(guardSkipped.tone == .incomplete)
    }

    @Test func noRunsAndUnreadRunsAreSaidAsSuch() {
        let empty = ChecksReading(.loaded([]))
        #expect(empty.guardLink.detail == "not run yet")
        #expect(empty.checksLink.detail == "none reported")
        #expect(empty.summary == "No checks reported for this commit yet.")

        let loading = ChecksReading(.loading)
        #expect([loading.guardLink.state, loading.checksLink.state] == [.unknown, .unknown])
        #expect(loading.summary == "Loading the checks from GitHub…")

        let unread = ChecksReading(.unavailable("HTTP 502"))
        #expect([unread.guardLink.state, unread.checksLink.state] == [.unknown, .unknown])
        #expect(unread.tone == .waiting)
    }

    @Test func checksWithoutTheGuardAreNotAllPassed() {
        let noGuard = ChecksReading(.loaded([run(2, "checks-node", "completed", "success")]))
        #expect(noGuard.guardLink.state == .pending)
        #expect(noGuard.summary == "The guard has not reported on this commit yet.")
        let guardOnly = ChecksReading(.loaded([guardPassed]))
        #expect(guardOnly.checksLink.state == .pending)
        #expect(guardOnly.summary == "Only the guard has reported on this commit so far.")
        let guardFailed = ChecksReading(.loaded([run(1, "guard", "completed", "failure"), run(2, "checks-node", "completed", "success")]))
        #expect(guardFailed.summary == "Guard failed: fix it before approving.")
    }
}

@Suite("pull request chain")
struct PullRequestChainTests {
    @Test func anAgentsPRIsApprovedNotMergedByTheApproval() {
        let plan = Plan.approve(pullRequest(merge: nil, queue: nil))
        let before = pullRequestChain(plan: plan, specTicket: nil, checks: allPassed, progress: .awaiting)
        #expect(before.link(.approval)?.state == .now)
        #expect(before.link(.merge)?.detail == "after your approval")
        #expect(before.missing == "your approval")

        let after = pullRequestChain(plan: plan, specTicket: nil, checks: allPassed, progress: .succeeded)
        #expect(after.link(.approval)?.state == .done)
        #expect(after.link(.merge)?.state == .pending)
        #expect(after.link(.merge)?.detail == "auto-merge or by hand")
        #expect(after.missing == "the merge")
    }

    @Test func theOwnersOwnPRMergesOrQueues() {
        let merges = Plan.approve(pullRequest(merge: true, queue: nil))
        #expect(pullRequestChain(plan: merges, specTicket: nil, checks: allPassed, progress: .awaiting).link(.merge)?.detail
            == "right after you confirm")
        let merged = pullRequestChain(plan: merges, specTicket: nil, checks: allPassed, progress: .succeeded)
        #expect(merged.link(.merge)?.state == .done)
        #expect(merged.missing == nil)

        let queues = Plan.approve(pullRequest(merge: true, queue: true))
        #expect(pullRequestChain(plan: queues, specTicket: nil, checks: allPassed, progress: .awaiting).link(.merge)?.detail
            == "through the merge queue")
        let queued = pullRequestChain(plan: queues, specTicket: nil, checks: allPassed, progress: .succeeded)
        #expect(queued.link(.merge)?.state == .pending)
        #expect(queued.link(.merge)?.detail == "in the merge queue")
        #expect(queued.missing == "the merge queue")
    }

    @Test func turningOnMergesTheBootstrapPR() {
        let plan = Plan.turnOn(pullRequest(merge: nil, queue: true))
        #expect(pullRequestChain(plan: plan, specTicket: nil, checks: allPassed, progress: .awaiting).link(.merge)?.detail
            == "right after you confirm")
        #expect(pullRequestChain(plan: plan, specTicket: nil, checks: allPassed, progress: .succeeded).link(.merge)?.state == .done)
    }

    @Test func aFailedRunClaimsNeitherApprovalNorMerge() {
        let chain = pullRequestChain(
            plan: .approve(pullRequest(merge: true, queue: nil)), specTicket: nil, checks: allPassed, progress: .failed)
        #expect(chain.link(.approval)?.state == .unknown)
        #expect(chain.link(.merge)?.state == .unknown)
        #expect(chain.missing == nil)
        let cancelled = pullRequestChain(
            plan: .approve(pullRequest(merge: nil, queue: nil)), specTicket: nil, checks: allPassed, progress: .cancelled)
        #expect(cancelled.link(.approval)?.state == .pending)
        #expect(cancelled.missing == "your approval")
    }

    @Test func brokenOrUnfinishedChecksComeBeforeTheApproval() {
        let plan = Plan.approve(pullRequest(merge: nil, queue: nil))
        let failing = ChecksReading(.loaded([guardPassed, run(2, "checks-node", "completed", "timed_out")]))
        #expect(pullRequestChain(plan: plan, specTicket: nil, checks: failing, progress: .succeeded).missing == "checks failed")
        #expect(pullRequestChain(plan: plan, specTicket: nil, checks: ChecksReading(.loading), progress: .awaiting).missing
            == "the checks")
        let spec = pullRequestChain(plan: plan, specTicket: "SHOP-12", checks: allPassed, progress: .awaiting)
        #expect(spec.links.first?.kind == .spec)
        #expect(spec.links.first?.detail == "SHOP-12 · in this change")
    }
}
