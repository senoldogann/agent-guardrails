import Foundation
import Testing

@testable import GuardrailsCore

private func project(_ state: ProjectState, mode: ApprovalMode?, queue: Bool) -> Project {
    Project(
        repo: "acme/shop", state: state, note: "ruleset active", private: true, fork: false, branch: "main", pushed: "",
        openPRs: 0, setupURL: "", setupTitle: "", mode: mode, agentApp: .installed, mergeQueue: queue, organization: true)
}

private func run(_ id: Int, _ name: String, _ status: String, _ conclusion: String?, started: String) -> CheckRun {
    CheckRun(
        id: id, name: name, status: status, conclusion: conclusion, htmlURL: "https://github.com/acme/shop/runs/\(id)",
        startedAt: started, completedAt: nil, app: nil)
}

private func run(_ id: Int, _ name: String, _ status: String, _ conclusion: String?) -> CheckRun {
    run(id, name, status, conclusion, started: "2026-11-20T10:00:00Z")
}

private let guardPassed = run(1, "guard", "completed", "success")

private func pullRequest(merge: Bool?, queue: Bool?) -> PullRequestPlan {
    PullRequestPlan(
        repo: "acme/shop", pr: 7, url: "https://github.com/acme/shop/pull/7", title: "t",
        sha: String(repeating: "a", count: 40), base: String(repeating: "b", count: 40), files: [], merge: merge,
        mergeQueue: queue, ownPush: nil, author: nil, pushedBy: nil, pushedAt: nil, lockScope: nil, leavesReviewMode: nil)
}

private let approve = Plan.approve(pullRequest(merge: nil, queue: nil))
private let turnOn = Plan.turnOn(pullRequest(merge: nil, queue: nil))
private let allPassed = ChecksReading(.loaded([guardPassed, run(2, "checks-node", "completed", "success")]))

/// An inbox alarm as `guardrails inbox --json` words it.
private func alarm(_ repo: String) -> InboxItem {
    InboxItem(
        kind: .alarm, repo: repo, url: "", title: repo,
        note: "\(repo): the agent-guardrails-review ruleset is disabled. If you did not change it, check the audit log; restore with: guardrails on \(repo)",
        sha: "")
}

private func inbox(_ alarms: [InboxItem]) -> InboxSnapshot {
    InboxSnapshot(alarms: alarms, notes: [], repos: [], approvals: [], turnOns: [], answers: [], inProgress: [])
}

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

    @Test func anEnforcedRepositoryWithAnInboxAlarmIsShownAsAnAlarm() {
        // `on` only says the branch ruleset is active; a disabled review ruleset shows in the inbox, not in the state.
        let alarmed = inbox([alarm("Acme/Shop"), alarm("acme/other"), alarm("")])
        let shown = shownProject(project(.on, mode: .status, queue: true), inbox: alarmed)
        #expect(shown.state == .alarm)
        #expect(shown.note == "the agent-guardrails-review ruleset is disabled. If you did not change it, check the audit log.")
        #expect(!shown.canSwitchToReviewMode && !shown.canTurnOnMergeQueue)
        #expect(repositoryChain(shown).link(.ruleset)?.state == .failed)
        #expect(groupProjects(shownProjects([project(.on, mode: .status, queue: false)], inbox: alarmed), matching: "")
            .needsYou.count == 1)
        // Nothing else changes: no alarm for it, or a state the inbox does not overrule.
        #expect(shownProject(project(.on, mode: .review, queue: false), inbox: inbox([alarm("acme/other")])).state == .on)
        #expect(shownProject(project(.off, mode: nil, queue: false), inbox: alarmed).state == .off)
        #expect(alarmed.alarms(of: "acme/shop").map(\.repo) == ["Acme/Shop"])
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

    @Test func anEnforcedRepositoryIsNotConfirmedBeforeTheInboxIsRead() {
        // Until the inbox reads every kit ruleset, a disabled review ruleset has raised no alarm yet.
        let chain = repositoryChainBeforeInbox(project(.on, mode: .review, queue: true))
        #expect(chain.link(.ruleset)?.state == .unknown)
        #expect(chain.link(.approval)?.state == .unknown)
        #expect(!chain.links.contains { $0.kind != .kit && $0.state == .done })
        #expect(!chain.links.contains { $0.detail.contains("active") || $0.detail.contains("per commit") })
        // The inbox only ever turns an enforced repository into an alarm: every other state is drawn as before.
        for state in [ProjectState.alarm, .elsewhere, .ready, .off, .noAdmin] {
            let other = project(state, mode: nil, queue: false)
            #expect(repositoryChainBeforeInbox(other) == repositoryChain(other), "\(state)")
        }
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
        #expect(summarizeChecks(allPassed, for: approve)
            == ChecksSentence(text: "Every check reported on this commit passed.", tone: .passed))
    }

    @Test func aFailureWinsOverRunningChecks() {
        let reading = ChecksReading(
            .loaded([
                guardPassed, run(2, "checks-node", "in_progress", nil), run(3, "security", "completed", "failure"),
            ]))
        #expect(reading.checksLink.state == .failed)
        #expect(reading.checksLink.detail == "1 failing")
        #expect(summarizeChecks(reading, for: approve)
            == ChecksSentence(text: "Checks 1 failing: fix it before approving.", tone: .problem))
    }

    @Test func runningChecksAreNotAnEmptyList() {
        let reading = ChecksReading(
            .loaded([guardPassed, run(2, "checks-node", "in_progress", nil), run(3, "security", "completed", "success")]))
        #expect(reading.checksLink.state == .now)
        #expect(reading.checksLink.detail == "1 running, 1 passed")
        #expect(summarizeChecks(reading, for: approve).text == "Checks are still running on this commit.")
        let guardRunning = ChecksReading(.loaded([run(1, "guard", "queued", nil), run(2, "checks-node", "completed", "success")]))
        #expect(guardRunning.guardLink.state == .now)
        #expect(summarizeChecks(guardRunning, for: approve).text == "Checks are still running on this commit.")
    }

    @Test func skippedAndNeutralChecksAreNotPasses() {
        let reading = ChecksReading(
            .loaded([
                guardPassed, run(2, "checks-node", "completed", "success"), run(3, "security", "completed", "skipped"),
                run(4, "lint", "completed", "neutral"),
            ]))
        #expect(reading.checksLink.state == .done)
        #expect(reading.checksLink.detail == "1 passed, 1 skipped, 1 neutral")
        #expect(summarizeChecks(reading, for: approve) == ChecksSentence(
            text: "No check failed on this commit, but not all passed: 2 passed, 1 skipped, 1 neutral.", tone: .incomplete))

        let nothingRan = ChecksReading(.loaded([guardPassed, run(2, "checks-node", "completed", "skipped")]))
        #expect(nothingRan.checksLink.state == .unknown)
        #expect(nothingRan.checksLink.detail == "1 skipped, none passed")
        #expect(summarizeChecks(nothingRan, for: approve).tone == .incomplete)
    }

    @Test func onlyASucceededGuardPassesAsInTheCLI() {
        // pr_states blocks a PR whose newest guard run did not succeed, skipped and neutral included.
        let guardSkipped = ChecksReading(.loaded([run(1, "guard", "completed", "skipped"), run(2, "checks-node", "completed", "success")]))
        #expect(guardSkipped.guardLink.state == .failed)
        #expect(guardSkipped.guardLink.detail == "skipped")
        #expect(summarizeChecks(guardSkipped, for: approve).text == "Guard skipped: fix it before approving.")
        // The guard is the run named exactly "guard", as the CLI and the ruleset name it.
        let lookAlike = ChecksReading(.loaded([run(1, "Guard", "completed", "success"), run(2, "checks-node", "completed", "success")]))
        #expect(lookAlike.guardRun == nil)
        #expect(lookAlike.checks.map(\.name) == ["Guard", "checks-node"])
    }

    @Test func aCancelledGuardRunThatANewerRunReplacedIsNoFailure() {
        // The guard's concurrency group cancels the run a draft push started once `gh pr ready` starts another.
        let replaced = ChecksReading(
            .loaded([
                run(1, "guard", "completed", "cancelled", started: "2026-11-20T10:00:00Z"),
                run(5, "guard", "completed", "success", started: "2026-11-20T10:00:09Z"),
                run(2, "checks-node", "completed", "success"),
            ]))
        #expect(replaced.guardLink.state == .done)
        #expect(replaced.replacedIDs == [1])
        #expect(summarizeChecks(replaced, for: approve).tone == .passed)
        // Start times have whole seconds; the run ids say which run is newer.
        let sameSecond = ChecksReading(
            .loaded([
                run(10, "guard", "completed", "cancelled", started: "2026-11-20T10:00:00Z"),
                run(11, "guard", "completed", "success", started: "2026-11-20T10:00:00Z"),
            ]))
        #expect(sameSecond.guardLink.state == .done)
        // A real failure wins over a later success, as in the CLI: a workflow the PR adds could report a run of that name.
        let failedFirst = ChecksReading(
            .loaded([
                run(1, "guard", "completed", "failure", started: "2026-11-20T10:00:00Z"),
                run(5, "guard", "completed", "success", started: "2026-11-20T10:00:09Z"),
            ]))
        #expect(failedFirst.guardLink.state == .failed)
        #expect(failedFirst.guardLink.detail == "failed")
        #expect(failedFirst.replacedIDs.isEmpty)
        // Every real failure stays a failure in the list, not only the one that decides.
        let twoFailures = ChecksReading(
            .loaded([
                run(1, "guard", "completed", "failure"), run(3, "guard", "completed", "timed_out"),
                run(5, "guard", "completed", "success"),
            ]))
        #expect(twoFailures.replacedIDs.isEmpty)
        // A cancelled run nothing replaced did not pass: it says so.
        let onlyCancelled = ChecksReading(.loaded([run(1, "guard", "completed", "cancelled")]))
        #expect(onlyCancelled.guardLink.state == .failed)
        #expect(onlyCancelled.guardLink.detail == "cancelled")
    }

    @Test func aRerunCheckCountsByItsNewestRun() {
        let reading = ChecksReading(
            .loaded([
                guardPassed,
                run(2, "checks-node", "completed", "cancelled", started: "2026-11-20T10:00:00Z"),
                run(6, "checks-node", "queued", nil, started: ""),
            ]))
        #expect(reading.checks.map(\.id) == [6])
        #expect(reading.checksLink.state == .now)
        #expect(reading.replacedIDs == [2])
    }

    @Test func noRunsAndUnreadRunsAreSaidAsSuch() {
        let empty = ChecksReading(.loaded([]))
        #expect(empty.guardLink.detail == "not run yet")
        #expect(empty.checksLink.detail == "none reported")
        #expect(summarizeChecks(empty, for: approve).text == "No checks reported for this commit yet.")

        let loading = ChecksReading(.loading)
        #expect([loading.guardLink.state, loading.checksLink.state] == [.unknown, .unknown])
        #expect(summarizeChecks(loading, for: approve).text == "Loading the checks from GitHub…")

        let unread = ChecksReading(.unavailable("HTTP 502"))
        #expect([unread.guardLink.state, unread.checksLink.state] == [.unknown, .unknown])
        #expect(summarizeChecks(unread, for: approve).tone == .waiting)
    }

    @Test func checksWithoutTheGuardAreNotAllPassed() {
        let noGuard = ChecksReading(.loaded([run(2, "checks-node", "completed", "success")]))
        #expect(noGuard.guardLink.state == .pending)
        #expect(summarizeChecks(noGuard, for: approve).text == "The guard has not reported on this commit yet.")
        let guardOnly = ChecksReading(.loaded([guardPassed]))
        #expect(guardOnly.checksLink.state == .pending)
        #expect(summarizeChecks(guardOnly, for: approve).text == "Only the guard has reported on this commit so far.")
        let guardFailed = ChecksReading(.loaded([run(1, "guard", "completed", "failure"), run(2, "checks-node", "completed", "success")]))
        #expect(summarizeChecks(guardFailed, for: approve).text == "Guard failed: fix it before approving.")
    }

    @Test func aBootstrapPRWaitsForNoGuard() {
        // The guard runs from the default branch, which does not have it before the turn-on.
        let checksOnly = ChecksReading(.loaded([run(2, "checks-node", "completed", "success"), run(3, "security", "completed", "success")]))
        #expect(summarizeChecks(checksOnly, for: turnOn).tone == .passed)
        let securityFails = ChecksReading(.loaded([run(2, "checks-node", "completed", "success"), run(3, "security", "completed", "failure")]))
        #expect(summarizeChecks(securityFails, for: turnOn) == ChecksSentence(
            text: "Checks 1 failing: turning on merges this PR anyway, so look at it first.", tone: .problem))
    }

    @Test func thePullRequestWindowDropsACancelledRunANewerOneReplaced() throws {
        func detail(_ rollup: String) throws -> PullRequestDetail {
            try parsePullRequestDetail(
                """
                {"number":3,"title":"t","body":"","url":"u","state":"OPEN","isDraft":false,"author":null,"baseRefName":"main",
                 "headRefName":"x","headRefOid":"b527b50dc9f7e5130b5883226b7bc26704d42f53","additions":0,"deletions":0,
                 "changedFiles":0,"createdAt":"2026-11-20T10:00:00Z","updatedAt":"2026-11-20T10:00:00Z","reviewDecision":"",
                 "mergeStateStatus":"CLEAN","autoMergeRequest":null,"labels":[],"comments":[],"reviews":[],"commits":[],
                 "files":[],"statusCheckRollup":[\(rollup)]}
                """)
        }
        let replaced = try detail(
            """
            {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-11-20T10:00:00Z"},
            {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-20T10:00:00Z"}
            """)
        #expect(replaced.checks.map(\.outcome) == [.passed])
        // A failure next to a later success stays: an earlier failure of a check named guard can matter.
        let disagreeing = try detail(
            """
            {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-20T10:00:00Z"},
            {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-20T10:00:09Z"}
            """)
        #expect(disagreeing.checks.map(\.outcome) == [.failed, .passed])
        let cancelledAlone = try detail(
            #"{"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-11-20T10:00:00Z"}"#)
        #expect(cancelledAlone.checks.map(\.outcome) == [.failed])
    }
}

@Suite("pull request chain")
struct PullRequestChainTests {
    @Test func anAgentsPRIsApprovedNotMergedByTheApproval() {
        let before = pullRequestChain(plan: approve, specTicket: nil, checks: allPassed, progress: .awaiting)
        #expect(before.link(.approval)?.state == .now)
        #expect(before.link(.merge)?.detail == "auto-merge or by hand")
        #expect(before.missing == "your approval")

        let after = pullRequestChain(plan: approve, specTicket: nil, checks: allPassed, progress: .succeeded)
        #expect(after.link(.approval)?.state == .done)
        #expect(after.link(.approval)?.detail == "given for this commit")
        #expect(after.link(.merge)?.state == .pending)
        #expect(after.link(.merge)?.detail == "auto-merge or by hand")
        #expect(after.missing == "the merge")
    }

    @Test func theOwnersOwnPRMergesOrQueuesWithoutAReview() {
        let merges = Plan.approve(pullRequest(merge: true, queue: nil))
        #expect(pullRequestChain(plan: merges, specTicket: nil, checks: allPassed, progress: .awaiting).link(.merge)?.detail
            == "right after you confirm")
        let merged = pullRequestChain(plan: merges, specTicket: nil, checks: allPassed, progress: .succeeded)
        #expect(merged.link(.merge)?.state == .done)
        #expect(merged.link(.approval)?.detail == "confirmed by you, no GitHub review")
        #expect(merged.missing == nil)

        let queues = Plan.approve(pullRequest(merge: true, queue: true))
        #expect(pullRequestChain(plan: queues, specTicket: nil, checks: allPassed, progress: .awaiting).link(.merge)?.detail
            == "through the merge queue")
        let queued = pullRequestChain(plan: queues, specTicket: nil, checks: allPassed, progress: .succeeded)
        #expect(queued.link(.merge)?.state == .pending)
        #expect(queued.link(.merge)?.detail == "in the merge queue")
        #expect(queued.missing == "the merge queue")
    }

    @Test func turningOnMergesTheBootstrapPRWithoutAGuard() {
        let checksOnly = ChecksReading(.loaded([run(2, "checks-node", "completed", "success")]))
        let before = pullRequestChain(plan: turnOn, specTicket: nil, checks: checksOnly, progress: .awaiting)
        #expect(before.link(.guardRun) == nil)
        #expect(before.link(.merge)?.detail == "right after you confirm")
        #expect(before.missing == "your approval")
        let failing = ChecksReading(.loaded([run(3, "security", "completed", "failure")]))
        #expect(pullRequestChain(plan: turnOn, specTicket: nil, checks: failing, progress: .awaiting).missing == "your approval")
        let after = pullRequestChain(plan: turnOn, specTicket: nil, checks: checksOnly, progress: .succeeded)
        #expect(after.link(.merge)?.state == .done)
        #expect(after.missing == nil)
        // A guard that did run (the default branch still had one) is shown.
        #expect(pullRequestChain(plan: turnOn, specTicket: nil, checks: allPassed, progress: .awaiting).link(.guardRun) != nil)
    }

    @Test func aRunUnderWayOrFailedIsMissingNothingAndClaimsNothing() {
        let merges = Plan.approve(pullRequest(merge: true, queue: nil))
        let working = pullRequestChain(plan: merges, specTicket: nil, checks: allPassed, progress: .working)
        #expect(working.missing == nil)
        #expect(working.link(.merge)?.state == .now)
        let failed = pullRequestChain(plan: merges, specTicket: nil, checks: allPassed, progress: .failed)
        #expect(failed.link(.approval)?.state == .unknown)
        #expect(failed.link(.merge)?.state == .unknown)
        #expect(failed.missing == nil)
        let cancelled = pullRequestChain(plan: approve, specTicket: nil, checks: allPassed, progress: .cancelled)
        #expect(cancelled.link(.approval)?.state == .pending)
        #expect(cancelled.missing == "your approval")
    }

    @Test func aDoneMergeOutranksOlderCheckResults() {
        // The board does not reload the checks by itself: after the merge they may still read as running.
        let stale = ChecksReading(.loaded([guardPassed, run(2, "checks-node", "in_progress", nil)]))
        let merged = pullRequestChain(
            plan: .approve(pullRequest(merge: true, queue: nil)), specTicket: nil, checks: stale, progress: .succeeded)
        #expect(merged.missing == nil)
    }

    @Test func brokenOrUnfinishedChecksComeBeforeTheApproval() {
        let failing = ChecksReading(.loaded([guardPassed, run(2, "checks-node", "completed", "timed_out")]))
        #expect(pullRequestChain(plan: approve, specTicket: nil, checks: failing, progress: .awaiting).missing == "checks failed")
        #expect(pullRequestChain(plan: approve, specTicket: nil, checks: ChecksReading(.loading), progress: .awaiting).missing
            == "the checks")
        let spec = pullRequestChain(plan: approve, specTicket: "SHOP-12", checks: allPassed, progress: .awaiting)
        #expect(spec.links.first?.kind == .spec)
        #expect(spec.links.first?.detail == "SHOP-12 · in this change")
    }
}
