import Foundation
import Testing

@testable import GuardrailsCore

@Suite("reports")
struct ReportTests {
    private let output = """
        {"repo":"acme/shop","days":30,"since":"2026-10-20T00:00:00Z","prs":5,"merged":{"total":3,"agent":2,"people":1,"otherBots":0},"approve":{"count":2,"median":3600,"p90":7200},"merge":{"count":3,"median":10800,"p90":21600},"reapproved":1,"guardFailed":1,"checksFailed":1,"failed":2,"failedThenMerged":1,"adminMerges":[{"number":13,"title":"docs: x","url":"u13","mergedBy":"owner","mergedAt":"2026-11-04T08:10:00Z"}],"partial":[16],"rulesetChanges":[{"time":"2026-11-06T09:30:00Z","actor":"owner","ruleset":"agent-guardrails","changes":["enforcement disabled → active","removed rule non_fast_forward"]}]}
        {"repo":"acme/quiet","days":30,"since":"2026-10-20T00:00:00Z","prs":0,"merged":{"total":0,"agent":0,"people":0,"otherBots":0},"approve":{"count":0,"median":null,"p90":null},"merge":{"count":0,"median":null,"p90":null},"reapproved":0,"guardFailed":0,"checksFailed":0,"failed":0,"failedThenMerged":0,"adminMerges":[],"partial":[],"rulesetChanges":[]}
        """

    @Test func parsesOneReportPerRepository() throws {
        let reports = try parseReports(output)
        #expect(reports.map(\.repo) == ["acme/shop", "acme/quiet"])
        #expect(reports[0].adminMerges.map(\.number) == [13])
        #expect(reports[0].rulesetChanges.first?.changes.count == 2)
        #expect(reports[1].approve == DurationStats(count: 0, median: nil, p90: nil))
    }

    @Test func refusesALineItCannotRead() {
        #expect(throws: JSONLinesError.self) { try parseReports("{\"repo\":\"acme/shop\"}") }
    }

    @Test func saysTheNumbersInWords() throws {
        let busy = try parseReports(output)[0]
        #expect(mergedSentence(busy) == "3 merged: 2 by the agent App, 1 by people")
        #expect(durationSentence(busy.approve, none: "-") == "Median 1 h, 90th percentile 2 h, over 2 pull requests")
        #expect(reapprovalSentence(busy) == "1 pull request needed a new approval after a push")
        #expect(checksSentence(busy) == "2 pull requests had a failing run (guard 1, checks 1); 1 merged after a later green run")
        #expect(adminMergeSentence(busy) == "1 merged without an approval on its final commit")
    }

    @Test func saysWhenThereIsNothing() throws {
        let quiet = try parseReports(output)[1]
        #expect(mergedSentence(quiet) == "None merged")
        #expect(durationSentence(quiet.merge, none: "No pull request merged") == "No pull request merged")
        #expect(reapprovalSentence(quiet) == "None needed a new approval after a push")
        #expect(checksSentence(quiet) == "No failing guard or checks run")
        #expect(adminMergeSentence(quiet) == "Every merge had an approval on its final commit")
    }

    @Test func formatsSpansAsTheCLIDoes() {
        #expect(formatSpan(seconds: 45) == "45 s")
        #expect(formatSpan(seconds: 85) == "1 min")
        #expect(formatSpan(seconds: 5400) == "1.5 h")
        #expect(formatSpan(seconds: 7200) == "2 h")
        #expect(formatSpan(seconds: 259_200) == "3 days")
        #expect(formatSpan(seconds: 190_000) == "2.1 days")
    }

    @Test func reportsAreABrowsePage() {
        let strip = TabStrip.initial.showing(.reports)
        #expect(strip.tabs == [.reports])
        #expect(WorkspacePage.reports.isBrowsePage)
    }
}
