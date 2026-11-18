import Foundation
import Testing

@testable import GuardrailsCore

@Suite("evidence")
struct EvidenceTests {
    @Test func readsTheGateStepsAndTheLastMutationVerdict() {
        // As GitHub serves a job log: timestamps, color codes, and test output that imitates a verdict.
        let log = """
            2026-11-17T10:54:01.0765295Z ##[group]Run make ci BASE_SHA="$BASE_SHA"
            2026-11-17T10:54:01.0765925Z \u{1B}[36;1mmake ci BASE_SHA="$BASE_SHA"\u{1B}[0m
            2026-11-17T10:54:01.1Z === spec gate for SHOP-12 at 0123abc ===
            2026-11-17T10:54:01.2Z $ make verify-red
            2026-11-17T10:54:01.3Z [exit 0]
            2026-11-17T10:54:01.4Z === full gate at b527b50 ===
            2026-11-17T10:54:01.5Z $ make typecheck
            2026-11-17T10:54:01.6Z 0 errors, 0 warnings, 0 notes
            2026-11-17T10:54:01.7Z [exit 0]
            2026-11-17T10:54:01.8Z $ make test
            2026-11-17T10:54:01.9Z mutants: 99 killed, 0 accepted, 0 invalid, 0 failing
            2026-11-17T10:54:02.0Z [exit 0]
            2026-11-17T10:54:02.1Z === mutation gate for changes since 0c9a7b5 ===
            2026-11-17T10:54:02.2Z mutation scope: 2 file(s)
            2026-11-17T10:54:02.3Z mutants: 44 killed, 1 accepted, 2 invalid, 1 failing
            """
        let report = parseGateLog(log)
        #expect(report.gates.map(\.kind) == [.spec(ticket: "SHOP-12"), .full])
        #expect(report.gates[1].steps == [GateStep(name: "typecheck", exitCode: 0), GateStep(name: "test", exitCode: 0)])
        #expect(report.mutation == .judged(MutationCounts(killed: 44, accepted: 1, invalid: 2, failing: 1)))
    }

    @Test func tellsAnEmptyScopeFromAnUnfinishedGate() {
        let empty = parseGateLog("=== full gate at a ===\n=== mutation gate for changes since b ===\nmutation scope: 0 file(s)\n")
        #expect(empty.mutation == .nothingToMutate)
        let unfinished = parseGateLog("=== full gate at a ===\n=== mutation gate for changes since b ===\nmutation scope: 3 file(s)\n")
        #expect(unfinished.mutation == .unfinished)
        let failedEarly = parseGateLog("=== full gate at a ===\n$ make lint\n")
        #expect(failedEarly.mutation == .notRun)
        #expect(failedEarly.gates[0].steps == [GateStep(name: "lint", exitCode: nil)])
    }

    @Test func ordersChecksFailedFirstAndKnowsKitGates() throws {
        let json = """
            {"total_count":3,"check_runs":[
            {"id":1,"name":"guard","status":"completed","conclusion":"success","html_url":"h1","started_at":"2026-11-17T10:53:54Z","completed_at":"2026-11-17T10:54:03Z","app":{"slug":"github-actions"}},
            {"id":2,"name":"checks-python","status":"completed","conclusion":"failure","html_url":"h2","started_at":null,"completed_at":null,"app":{"slug":"github-actions"}},
            {"id":3,"name":"checks-node","status":"in_progress","conclusion":null,"html_url":"h3","started_at":"2026-11-17T10:53:54Z","completed_at":null,"app":{"slug":"other"}}
            ]}
            """
        let runs = try parseCheckRuns(json)
        #expect(runs.map(\.name) == ["checks-python", "checks-node", "guard"])
        #expect(runs.map(\.isKitGate) == [true, false, false])
        #expect(runs[2].duration == 9)
        #expect([9.4, 60, 125].map(shortDuration) == ["9s", "1m 0s", "2m 5s"])
    }

    @Test func findsTheTicketOfASpecTheChangeCarries() {
        let files = ["src/a.py", "specs/notes.md", "specs/x/y", "specs/SHOP-12/acceptance-criteria.md"]
        #expect(ticketID(changing: files.map { PlannedFile(path: $0, marker: "") }) == "SHOP-12")
        #expect(ticketID(changing: [PlannedFile(path: "src/a.py", marker: "")]) == nil)
    }
}

@Suite("activity")
struct ActivityTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ offset: TimeInterval, repo: String) -> ActivityEntry {
        ActivityEntry(
            date: base.addingTimeInterval(offset), outcome: .succeeded, summary: "Approved", repo: repo,
            title: "feat: x", detail: "abc1234", url: "https://github.com/\(repo)/pull/1")
    }

    @Test func survivesARoundTripThroughTheFile() throws {
        let entries = [entry(0, repo: "acme/shop"), entry(60, repo: "acme/site")]
        let text = try entries.map(activityLine).joined(separator: "\n") + "\n"
        #expect(try parseActivity(text) == entries)
        #expect(throws: JSONLinesError.self) { try parseActivity("{not json}\n") }
    }

    @Test func listsTheNewestFirstAndTrimsTheOldest() {
        let entries = [entry(0, repo: "a/x"), entry(120, repo: "a/y"), entry(60, repo: "a/x")]
        #expect(latestActivity(entries, limit: 2).map(\.date) == [base.addingTimeInterval(120), base.addingTimeInterval(60)])
        #expect(activity(of: "a/x", in: entries, limit: 5).map(\.date) == [base.addingTimeInterval(60), base])
        #expect(trimActivity(entries, keeping: 2).map(\.date) == [base.addingTimeInterval(60), base.addingTimeInterval(120)])
    }

    @Test func recordsWhatArrivedInTheInbox() {
        let item = InboxItem(kind: .approve, repo: "acme/shop", url: "u", title: "feat: x", note: "checks green")
        let logged = arrivalEntries([item], at: base)
        #expect(logged.map(\.summary) == ["Waiting for your approval"])
        #expect(logged.map(\.outcome) == [.arrived])
    }
}

@Suite("onboarding")
struct OnboardingTests {
    @Test func needsEveryRequiredStepButNotTheAgentApp() {
        let done = OnboardingFacts(kitFound: true, githubSignedIn: true, notificationsShown: true, agentRegistered: false, enforcedRepos: 2)
        #expect(onboardingIsComplete(onboardingSteps(done)))
        let loading = OnboardingFacts(kitFound: true, githubSignedIn: nil, notificationsShown: false, agentRegistered: nil, enforcedRepos: 0)
        let steps = onboardingSteps(loading)
        #expect(steps.map(\.state) == [.done, .checking, .todo, .checking, .todo])
        #expect(!onboardingIsComplete(steps))
    }

    @Test func showsGitHubsRepositoryKind() throws {
        let line = { (isPrivate: Bool, fork: Bool) in
            #"{"repo":"a/b","state":"off","note":"","private":\#(isPrivate),"fork":\#(fork),"branch":"main","pushed":"","openPRs":0,"setupURL":"","setupTitle":""}"#
        }
        let kinds = try parseProjects([line(true, true), line(true, false), line(false, false)].joined(separator: "\n")).map(\.kind)
        #expect(kinds == [.fork, .privateRepo, .publicRepo])
    }
}
