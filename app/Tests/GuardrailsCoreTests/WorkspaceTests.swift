import Foundation
import Testing

@testable import GuardrailsCore

@Suite("workspace tabs")
struct WorkspaceTests {
    private let pr3 = WorkspacePage.pullRequest(PullRequestRef(repo: "a/b", number: 3))
    private let pr8 = WorkspacePage.pullRequest(PullRequestRef(repo: "a/b", number: 8))
    private let review = WorkspacePage.review(UUID())

    @Test func browsePagesShareTheFirstTab() {
        let strip = TabStrip.initial.showing(.repository("a/b")).showing(.settings)
        #expect(strip.tabs == [.settings])
        #expect(strip.selected == .settings)
    }

    @Test func opensNextToTheSelectedTabAndNeverTwice() {
        let strip = TabStrip.initial.showing(pr3).showing(pr8).selecting(pr3).showing(review)
        #expect(strip.pages == [pr3, review, pr8])
        #expect(strip.showing(pr8).pages == [pr3, review, pr8])
        #expect(strip.showing(pr8).selected == pr8)
        // A browse page keeps the other tabs open.
        #expect(strip.showing(.repository("a/c")).pages == [pr3, review, pr8])
    }

    @Test func closingSelectsTheNeighbor() {
        let strip = TabStrip.initial.showing(pr3).showing(pr8).showing(review)
        #expect(strip.pages == [pr3, pr8, review])
        #expect(strip.selecting(pr8).closing(pr8).selected == review)
        #expect(strip.closing(review).selected == pr8)
        #expect(strip.closing(pr3).selected == review)
        #expect(strip.closing(pr3).closing(pr8).closing(review).selected == .overview)
        #expect(strip.closing(.overview) == strip)
    }

    @Test func stepsAroundTheTabs() {
        let strip = TabStrip.initial.showing(pr3).showing(pr8)
        #expect(strip.stepping(by: 1).selected == .overview)
        #expect(strip.stepping(by: -1).selected == pr3)
        #expect(strip.selecting(.welcome) == strip)
    }
}
