import Foundation
import Testing

@testable import GuardrailsCore

private let base = "1111111111111111111111111111111111111111"
private let approvePlan = PullRequestPlan(
    repo: "acme/shop", pr: 7, url: "https://github.com/acme/shop/pull/7", title: "feat(A-1): x",
    sha: "abc1234def5678", base: base, files: [PlannedFile(path: "src/a.ts", marker: "")], merge: nil, mergeQueue: nil,
    ownPush: nil, author: nil, pushedBy: nil, pushedAt: nil, lockScope: nil, leavesReviewMode: nil)
private let workflowPlan = PullRequestPlan(
    repo: "acme/shop", pr: 8, url: "https://github.com/acme/shop/pull/8", title: "ci: y",
    sha: "0123456789abcdef", base: base, files: [PlannedFile(path: ".github/workflows/x.yml", marker: "!!")], merge: nil,
    mergeQueue: nil, ownPush: nil, author: nil, pushedBy: nil, pushedAt: nil, lockScope: nil, leavesReviewMode: nil)

@Suite("inbox")
struct InboxTests {
    @Test func groupsLinesByWhatTheOwnerDoes() throws {
        let output = """
            {"kind":"alarm","repo":"","url":"","title":"","note":"the kit install has local changes","sha":""}
            {"kind":"repo","repo":"acme/shop","url":"","title":"","note":"active","sha":""}
            {"kind":"approve","repo":"acme/shop","url":"u3","title":"feat: ready","note":"checks green","sha":""}
            {"kind":"wait","repo":"acme/shop","url":"u6","title":"feat: new","note":"guard is running","sha":""}
            {"kind":"turn-on","repo":"acme/new","url":"u9","title":"chore: install","note":"","sha":""}
            """
        let snapshot = try parseInbox(output)
        #expect(snapshot.alarms.count == 1)
        #expect(snapshot.hasKitInstallAlarm)
        #expect(snapshot.repos == [EnforcedRepo(name: "acme/shop", rulesetState: "active")])
        #expect(snapshot.approvals.map(\.url) == ["u3"])
        #expect(snapshot.inProgress.map(\.url) == ["u6"])
        #expect(snapshot.turnOns.map(\.repo) == ["acme/new"])
        #expect(!snapshot.isQuiet)
    }

    @Test func refusesUnknownKinds() {
        #expect(throws: InboxParseError.self) {
            try parseInbox(#"{"kind":"approved","repo":"a/b","url":"","title":"","note":"","sha":""}"#)
        }
    }

    @Test func reportsOnlyNewAlarmsApprovalsAndQuestions() throws {
        let before = try parseInbox(#"{"kind":"approve","repo":"a/b","url":"u1","title":"t","note":"n","sha":""}"#)
        let after = try parseInbox("""
            {"kind":"approve","repo":"a/b","url":"u1","title":"t","note":"n","sha":""}
            {"kind":"approve","repo":"a/b","url":"u2","title":"t2","note":"n","sha":""}
            {"kind":"answer","repo":"a/b","url":"u3","title":"spec: x","note":"2 questions","sha":""}
            {"kind":"alarm","repo":"a/c","url":"","title":"","note":"ruleset disabled","sha":""}
            {"kind":"wait","repo":"a/b","url":"u4","title":"t4","note":"checks running","sha":""}
            {"kind":"turn-on","repo":"a/d","url":"u5","title":"chore: install","note":"","sha":""}
            """)
        #expect(newAttentionItems(previous: before, current: after).map(\.kind) == [.alarm, .approve, .answer])
        #expect(newAttentionItems(previous: after, current: after).isEmpty)
        #expect(waitingCount(after) == 3)
        #expect(waitingCount(after, repo: "a/b") == 3)
        #expect(waitingCount(after, repo: "a/c") == 0)
    }

    @Test func notifiesAgainWhenAPushChangesAWaitingPR() throws {
        let before = try parseInbox(#"{"kind":"approve","repo":"a/b","url":"u1","title":"t","note":"checks green","sha":"aaa"}"#)
        let after = try parseInbox(#"{"kind":"approve","repo":"a/b","url":"u1","title":"t","note":"checks green","sha":"bbb"}"#)
        #expect(newAttentionItems(previous: before, current: after).map(\.sha) == ["bbb"])
        #expect(newAttentionItems(previous: after, current: after).isEmpty)
    }

    @Test func tellsGitHubFailuresApart() {
        func described(_ standardError: String) -> String {
            describeCommandFailure(
                CommandResult(status: 1, standardOutput: "", standardError: standardError), command: "guardrails inbox")
        }
        #expect(described("To get started with GitHub CLI, please run:  gh auth login").hasPrefix("GitHub CLI is not signed in"))
        #expect(described("gh: Bad credentials (HTTP 401)").hasPrefix("GitHub refused the GitHub CLI's login"))
        #expect(described("error connecting to api.github.com\ncheck your internet connection").hasPrefix("Offline"))
        #expect(described(#"Get "https://api.github.com/user": dial tcp: lookup api.github.com: no such host"#).hasPrefix("Offline"))
        #expect(described("gh: API rate limit exceeded for user").hasPrefix("GitHub's API rate limit"))
        #expect(described("error: not an owner/repo name: x") == "error: not an owner/repo name: x")
        #expect(described("") == "guardrails inbox exited with status 1")
    }

    @Test func routesEachNotificationToItsAction() {
        let approve = InboxItem(kind: .approve, repo: "a/b", url: "https://github.com/a/b/pull/1", title: "feat: x", note: "", sha: "")
        let answer = InboxItem(kind: .answer, repo: "a/b", url: "https://github.com/a/b/pull/2", title: "spec: y", note: "", sha: "")
        let update = InboxItem(kind: .alarm, repo: "", url: "", title: "update", note: "the kit install is behind", sha: "")
        let kitAlarm = InboxItem(kind: .alarm, repo: "", url: "", title: "", note: "the kit install has local changes", sha: "")
        let repoAlarm = InboxItem(kind: .alarm, repo: "a/c", url: "", title: "", note: "ruleset disabled", sha: "")
        #expect(inboxRoute(for: approve) == .review(url: "https://github.com/a/b/pull/1", title: "feat: x"))
        #expect(inboxRoute(for: answer) == .browser(url: "https://github.com/a/b/pull/2"))
        #expect(inboxRoute(for: update) == .update)
        #expect(inboxRoute(for: kitAlarm) == .projects)
        #expect(inboxRoute(for: repoAlarm) == .projects)
        #expect(notificationText(for: approve) == NotificationText(title: "Waiting for your approval", body: "a/b: feat: x"))
        #expect(notificationText(for: kitAlarm).body == "Kit install: the kit install has local changes")
        #expect(notificationText(for: repoAlarm) == NotificationText(title: "Guardrails alarm", body: "a/c: ruleset disabled"))
    }

    @Test func dropsOnlyTheRestoreCommandBesideARestoreButton() {
        func alarm(_ repo: String, _ note: String) -> InboxItem {
            InboxItem(kind: .alarm, repo: repo, url: "", title: "", note: note, sha: "")
        }
        let cli = "a/c: the agent-guardrails ruleset is missing. If you did not change it, check the audit log; restore with: guardrails on a/c"
        #expect(alarm("a/c", cli).noteBesideRestore
            == "a/c: the agent-guardrails ruleset is missing. If you did not change it, check the audit log.")
        #expect(alarm("a/other", cli).noteBesideRestore == cli)
        #expect(alarm("a/c", "a/c: something else").noteBesideRestore == "a/c: something else")
    }
}

@Suite("events and confirmations")
struct ConfirmationTests {
    @Test func parsesEveryPlanAndConfirmation() throws {
        let approve = try parseEvent(
            #"{"event":"plan","action":"approve","repo":"acme/shop","pr":7,"url":"u","title":"t","sha":"abc1234def","files":[{"marker":"!!","path":".github/workflows/x.yml"}]}"#)
        guard case .plan(.approve(let pr)) = approve else {
            Issue.record("not an approve plan: \(approve)")
            return
        }
        #expect(pr.hasWorkflowChanges && pr.needsDiffReview && pr.shortSHA == "abc1234")
        let off = try parseEvent(
            #"{"event":"plan","action":"off","repo":"acme/shop","branch":"main","removed":["D\t.agent/bin/x"],"notes":[]}"#)
        #expect(off == .plan(.turnOff(RemovalPlan(repo: "acme/shop", branch: "main", removed: ["D\t.agent/bin/x"], notes: []))))
        #expect(try parseEvent(#"{"event":"confirm","step":"commit","expect":"abc1234"}"#)
            == .confirm(ConfirmRequest(step: .commit, expect: "abc1234")))
        #expect(throws: EventParseError.self) { try parseEvent(#"{"event":"plan","action":"merge"}"#) }
    }

    @Test func answersOnlyWhatThePlanSays() throws {
        #expect(try confirmationAnswer(for: ConfirmRequest(step: .commit, expect: "abc1234"), plan: .approve(approvePlan)) == "abc1234")
        #expect(throws: ConfirmationError.self) {
            try confirmationAnswer(for: ConfirmRequest(step: .commit, expect: "fffffff"), plan: .approve(approvePlan))
        }
        #expect(throws: ConfirmationError.self) {
            try confirmationAnswer(for: ConfirmRequest(step: .commit, expect: "abc1234"), plan: nil)
        }
        #expect(throws: ConfirmationError.self) {
            try confirmationAnswer(for: ConfirmRequest(step: .workflows, expect: "workflows"), plan: .approve(approvePlan))
        }
        #expect(try confirmationAnswer(for: ConfirmRequest(step: .workflows, expect: "workflows"), plan: .approve(workflowPlan)) == "workflows")
        let removal = Plan.turnOff(RemovalPlan(repo: "acme/shop", branch: "main", removed: [], notes: []))
        #expect(try confirmationAnswer(for: ConfirmRequest(step: .repo, expect: "acme/shop"), plan: removal) == "acme/shop")
        #expect(throws: ConfirmationError.self) {
            try confirmationAnswer(for: ConfirmRequest(step: .repo, expect: "acme/other"), plan: removal)
        }
        #expect(throws: ConfirmationError.self) {
            try confirmationAnswer(for: ConfirmRequest(step: .repo, expect: "acme/shop"), plan: .approve(approvePlan))
        }
    }

    @Test func updatesOnlyToThePlannedCommit() throws {
        let event = try parseEvent(
            #"{"event":"plan","action":"update","from":"1111111aaaa","to":"2222222bbbb","fromVersion":"0.1.0","toVersion":"0.2.0","commits":["2222222 feat: x"]}"#)
        guard case .plan(.update(let update)) = event else {
            Issue.record("expected an update plan, got \(event)")
            return
        }
        #expect(update.shortTo == "2222222" && update.commits == ["2222222 feat: x"])
        #expect(try confirmationAnswer(for: ConfirmRequest(step: .commit, expect: "2222222"), plan: .update(update)) == "2222222")
        #expect(throws: ConfirmationError.self) {
            try confirmationAnswer(for: ConfirmRequest(step: .commit, expect: "1111111"), plan: .update(update))
        }
        #expect(throws: ConfirmationError.self) {
            try confirmationAnswer(for: ConfirmRequest(step: .repo, expect: "acme/shop"), plan: .update(update))
        }
        #expect(ownerCheckReason(for: ConfirmRequest(step: .commit, expect: "2222222"), plan: .update(update))
            == "update the kit install to commit 2222222 (version 0.2.0)")
    }

    @Test func confirmsOnlyAFileListPinnedToABase() throws {
        let event = try parseEvent(
            #"{"event":"plan","action":"approve","repo":"acme/shop","pr":7,"url":"u","title":"t","sha":"abc1234def","base":"1111111111111111111111111111111111111111","files":[{"marker":"","path":"src/a.ts"}]}"#)
        guard case .plan(.approve(let pr)) = event else {
            Issue.record("not an approve plan: \(event)")
            return
        }
        #expect(pr.base == base)
        #expect(pr.compareURL == "https://github.com/acme/shop/compare/\(base)...abc1234def")
        #expect(try confirmationAnswer(for: ConfirmRequest(step: .commit, expect: "abc1234"), plan: .approve(pr)) == "abc1234")

        let unpinned = try parseEvent(
            #"{"event":"plan","action":"approve","repo":"acme/shop","pr":7,"url":"u","title":"t","sha":"abc1234def","files":[]}"#)
        guard case .plan(.approve(let older)) = unpinned else {
            Issue.record("not an approve plan: \(unpinned)")
            return
        }
        #expect(older.compareURL == nil)
        #expect(throws: ConfirmationError.unpinnedBase) {
            try confirmationAnswer(for: ConfirmRequest(step: .commit, expect: "abc1234"), plan: .approve(older))
        }
        for badBase in ["main", "1111111", "ABCDEF1111111111111111111111111111111111", ""] {
            let plan = PullRequestPlan(
                repo: "acme/shop", pr: 7, url: "u", title: "t", sha: "abc1234def", base: badBase, files: [], merge: nil,
                mergeQueue: nil, ownPush: nil, author: nil, pushedBy: nil, pushedAt: nil, lockScope: nil, leavesReviewMode: nil)
            #expect(throws: ConfirmationError.unpinnedBase) {
                try confirmationAnswer(for: ConfirmRequest(step: .commit, expect: "abc1234"), plan: .turnOn(plan))
            }
        }
    }

    @Test func namesTheMergeOfTheOwnersOwnPR() throws {
        let event = try parseEvent(
            #"{"event":"plan","action":"approve","repo":"acme/shop","pr":9,"url":"u","title":"t","sha":"abc1234ffff","files":[],"merge":true}"#)
        guard case .plan(.approve(let pr)) = event else {
            Issue.record("expected an approve plan, got \(event)")
            return
        }
        #expect(pr.isOwnMerge && !approvePlan.isOwnMerge)
        #expect(ownerCheckReason(for: ConfirmRequest(step: .commit, expect: "abc1234"), plan: .approve(pr))
            == "merge your own acme/shop PR #9 at commit abc1234")
    }

    @Test func namesTheMergeQueueEntryOfTheOwnersOwnPR() throws {
        let event = try parseEvent(
            #"{"event":"plan","action":"approve","repo":"acme/team","pr":9,"url":"u","title":"t","sha":"abc1234ffff","files":[],"merge":true,"mergeQueue":true}"#)
        guard case .plan(.approve(let pr)) = event else {
            Issue.record("expected an approve plan, got \(event)")
            return
        }
        #expect(pr.isOwnQueueEntry && !approvePlan.isOwnQueueEntry)
        #expect(ownerCheckReason(for: ConfirmRequest(step: .commit, expect: "abc1234"), plan: .approve(pr))
            == "add your own acme/team PR #9 at commit abc1234 to the merge queue")
    }

    @Test func namesTheMergeQueueWhenTurningOn() throws {
        let event = try parseEvent(#"{"event":"plan","action":"on-repo","repo":"acme/team","branch":"main","mergeQueue":true}"#)
        guard case .plan(.turnOnRepo(let repoPlan)) = event else {
            Issue.record("expected an on-repo plan, got \(event)")
            return
        }
        #expect(repoPlan.withMergeQueue)
        #expect(try confirmationAnswer(for: ConfirmRequest(step: .repo, expect: "acme/team"), plan: .turnOnRepo(repoPlan)) == "acme/team")
        #expect(ownerCheckReason(for: ConfirmRequest(step: .repo, expect: "acme/team"), plan: .turnOnRepo(repoPlan))
            == "turn the guardrails on for acme/team with the merge queue")
        let older = try parseEvent(#"{"event":"plan","action":"on-repo","repo":"acme/shop","branch":"main"}"#)
        #expect(older == .plan(.turnOnRepo(RepoPlan(repo: "acme/shop", branch: "main", mergeQueue: nil, mode: nil, leavesReviewMode: nil))))
    }

    @Test func asksToUnlockOnlyWhenThePlanDropsALockedFile() throws {
        let event = try parseEvent(
            #"{"event":"plan","action":"approve","repo":"acme/shop","pr":7,"url":"u","title":"t","sha":"abc1234def","base":"1111111111111111111111111111111111111111","files":[{"marker":"!","path":"specs/A-1/spec.lock"}],"merge":false,"mergeQueue":false,"ownPush":false,"lockScope":[{"lock":"specs/A-1/spec.lock","path":"tests/a.test.ts","change":"dropped"},{"lock":"specs/A-1/spec.lock","path":"tests/b.test.ts","change":"added"}]}"#)
        guard case .plan(.approve(let pr)) = event else {
            Issue.record("not an approve plan: \(event)")
            return
        }
        #expect(pr.droppedLockedFiles.map(\.path) == ["tests/a.test.ts"])
        #expect(pr.needsDiffReview)
        let unlock = ConfirmRequest(step: .unlock, expect: "unlock")
        #expect(try confirmationAnswer(for: unlock, plan: .approve(pr)) == "unlock")
        #expect(throws: ConfirmationError.self) {
            try confirmationAnswer(for: ConfirmRequest(step: .unlock, expect: "workflows"), plan: .approve(pr))
        }
        // A plan that announced no dropped file never gets the unlock confirmation typed.
        #expect(throws: ConfirmationError.self) { try confirmationAnswer(for: unlock, plan: .approve(approvePlan)) }
        let addedOnly = try parseEvent(
            #"{"event":"plan","action":"approve","repo":"acme/shop","pr":7,"url":"u","title":"t","sha":"abc1234def","base":"1111111111111111111111111111111111111111","files":[],"lockScope":[{"lock":"specs/A-1/spec.lock","path":"tests/b.test.ts","change":"added"}]}"#)
        guard case .plan(.approve(let added)) = addedOnly else {
            Issue.record("not an approve plan: \(addedOnly)")
            return
        }
        #expect(throws: ConfirmationError.self) { try confirmationAnswer(for: unlock, plan: .approve(added)) }
        #expect(isFinalConfirmation(ConfirmRequest(step: .commit, expect: "abc1234"), plan: .approve(added)))
        #expect(!isFinalConfirmation(ConfirmRequest(step: .commit, expect: "abc1234"), plan: .approve(pr)))
        #expect(isFinalConfirmation(unlock, plan: .approve(pr)))
        #expect(ownerCheckReason(for: unlock, plan: .approve(pr)) == "confirm acme/shop PR #7 stops locking 1 spec-locked file(s)")
    }

    @Test func namesTheMergeOfAPRTheOwnerPushedLast() throws {
        let event = try parseEvent(
            #"{"event":"plan","action":"approve","repo":"acme/shop","pr":7,"url":"u","title":"t","sha":"abc1234ffff","files":[],"merge":true,"mergeQueue":false,"ownPush":true,"lockScope":[],"author":"agent[bot]","pushedBy":"owner","pushedAt":"2026-01-01T00:00:00Z"}"#)
        guard case .plan(.approve(let pr)) = event else {
            Issue.record("expected an approve plan, got \(event)")
            return
        }
        #expect(pr.isOwnPush && pr.isOwnMerge && !approvePlan.isOwnPush)
        #expect(ownerCheckReason(for: ConfirmRequest(step: .commit, expect: "abc1234"), plan: .approve(pr))
            == "merge all of agent[bot]'s acme/shop PR #7 at commit abc1234, whose newest push your account made")
        #expect(pr.ownPushNote.hasPrefix("Your account owner made the newest push (abc1234, 2026-01-01T00:00:00Z)."))
        #expect(pr.ownPushNote.contains("so this merges all of agent[bot]'s PR, not only that push"))
    }

    @Test func neverConfirmsLeavingReviewMode() throws {
        let event = try parseEvent(
            #"{"event":"plan","action":"on-repo","repo":"acme/shop","branch":"main","mergeQueue":false,"mode":"status","leavesReviewMode":true}"#)
        guard case .plan(let plan) = event else {
            Issue.record("expected a plan, got \(event)")
            return
        }
        #expect(plan.leavesReviewMode)
        #expect(throws: ConfirmationError.leavesReviewMode(repo: "acme/shop")) {
            try confirmationAnswer(for: ConfirmRequest(step: .repo, expect: "acme/shop"), plan: plan)
        }
        let stays = try parseEvent(
            #"{"event":"plan","action":"on-repo","repo":"acme/shop","branch":"main","mergeQueue":false,"mode":"status","leavesReviewMode":false}"#)
        guard case .plan(let staysPlan) = stays else {
            Issue.record("expected a plan, got \(stays)")
            return
        }
        #expect(try confirmationAnswer(for: ConfirmRequest(step: .repo, expect: "acme/shop"), plan: staysPlan) == "acme/shop")
    }

    @Test func knowsTheFinalStep() {
        #expect(isFinalConfirmation(ConfirmRequest(step: .commit, expect: "abc1234"), plan: .approve(approvePlan)))
        #expect(!isFinalConfirmation(ConfirmRequest(step: .commit, expect: "0123456"), plan: .approve(workflowPlan)))
        #expect(ownerCheckReason(for: ConfirmRequest(step: .commit, expect: "abc1234"), plan: .approve(approvePlan))
            == "approve acme/shop PR #7 at commit abc1234")
    }

    @Test func environmentIsAnAllowlist() {
        let environment = cliEnvironment(
            inherited: ["HOME": "/Users/o", "BASH_ENV": "/tmp/evil", "GH_TOKEN": "x", "PATH": "/evil"], eventsDescriptor: 3)
        #expect(environment["HOME"] == "/Users/o")
        #expect(environment["BASH_ENV"] == nil && environment["GH_TOKEN"] == nil)
        #expect(environment["PATH"] == cliSearchPath)
        #expect(environment["GUARDRAILS_EVENTS_FD"] == "3")
    }
}

/// Drives a fake CLI that behaves like bin/guardrails: it needs a terminal, writes a plan and a confirm
/// event to descriptor 3, and reads the confirmation from /dev/tty.
@Suite("terminal session")
struct TerminalSessionTests {
    private func fakeCLI() throws -> String {
        let script = """
            #!/bin/bash
            set -euo pipefail
            [[ -t 0 && -t 1 ]] || { echo "no terminal"; exit 3; }
            printf '%s\\n' '{"event":"plan","action":"off","repo":"acme/shop","branch":"main","removed":[],"notes":[]}' >&"$GUARDRAILS_EVENTS_FD"
            printf '%s\\n' '{"event":"confirm","step":"repo","expect":"acme/shop"}' >&"$GUARDRAILS_EVENTS_FD"
            read -r -p "Type acme/shop to continue: " typed </dev/tty
            [[ $typed == acme/shop ]] || { echo "mismatch"; exit 4; }
            echo "done"
            """
        let url = FileManager.default.temporaryDirectory.appending(path: "fake-guardrails-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func answersAConfirmationThroughThePseudoTerminal() async throws {
        let cli = try fakeCLI()
        let session = try TerminalSession(
            command: terminalCommand(cliPath: cli, arguments: []),
            environment: cliEnvironment(inherited: ProcessInfo.processInfo.environment, eventsDescriptor: eventsDescriptor))
        var plan: Plan?
        var terminal = ""
        var exit: Int32?
        for await output in session.output {
            switch output {
            case .event(.plan(let announced)): plan = announced
            case .event(.confirm(let request)): try session.send(try confirmationAnswer(for: request, plan: plan) + "\n")
            case .terminal(let text): terminal += text
            case .invalidEvent(let error): Issue.record("invalid event: \(error)")
            case .exited(let code): exit = code
            }
        }
        #expect(exit == 0, "terminal output: \(terminal)")
        #expect(terminal.contains("done"))
    }

    @Test func closingTheInputStopsTheCommand() async throws {
        let cli = try fakeCLI()
        let session = try TerminalSession(
            command: terminalCommand(cliPath: cli, arguments: []),
            environment: cliEnvironment(inherited: ProcessInfo.processInfo.environment, eventsDescriptor: eventsDescriptor))
        var exit: Int32?
        for await output in session.output {
            switch output {
            case .event(.confirm): session.closeInput()
            case .exited(let code): exit = code
            case .event(.plan), .terminal, .invalidEvent: break
            }
        }
        #expect(exit != nil && exit != 0)
    }
}
