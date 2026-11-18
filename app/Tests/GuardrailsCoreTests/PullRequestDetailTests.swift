import Foundation
import Testing

@testable import GuardrailsCore

@Suite("pull request detail")
struct PullRequestDetailTests {
    /// Shaped like `gh pr view --json` of a bot PR in review mode, trimmed to what the app reads.
    private func detail(state: String, isDraft: Bool, reviewDecision: String, merge: String, autoMerge: Bool) throws -> PullRequestDetail {
        let json = """
            {"number":3,"title":"docs: x","body":"","url":"https://github.com/a/b/pull/3","state":"\(state)",
             "isDraft":\(isDraft),"author":{"is_bot":true,"login":"app/agent"},"baseRefName":"main","headRefName":"docs/x",
             "headRefOid":"b527b50dc9f7e5130b5883226b7bc26704d42f53","additions":3,"deletions":0,"changedFiles":1,
             "createdAt":"2026-11-17T10:50:49Z","updatedAt":"2026-11-17T22:43:50Z","reviewDecision":"\(reviewDecision)",
             "mergeStateStatus":"\(merge)","autoMergeRequest":\(autoMerge ? #"{"mergeMethod":"SQUASH"}"# : "null"),"labels":[],
             "comments":[{"author":{"login":"owner"},"body":"Why?","createdAt":"2026-11-17T11:00:00Z","url":"u"}],
             "reviews":[{"author":{"login":"owner"},"state":"DISMISSED","body":"ok","submittedAt":"2026-11-17T10:53:05Z","commit":{"oid":"ef42"}}],
             "commits":[{"oid":"ef42a307","messageHeadline":"docs: x","committedDate":"2026-11-17T10:50:44Z","authors":[{"login":"owner","name":"O"}]}],
             "files":[{"path":"README.md","additions":3,"deletions":0,"changeType":"MODIFIED"}],
             "statusCheckRollup":[
               {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"d"},
               {"__typename":"CheckRun","name":"guard","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"d"},
               {"__typename":"CheckRun","name":"checks-python","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"d"},
               {"__typename":"StatusContext","context":"merge-approval","state":"PENDING","targetUrl":null}]}
            """
        return try parsePullRequestDetail(json)
    }

    @Test func offersAMergeOnlyWhenApprovedAndClean() throws {
        let approved = try detail(state: "OPEN", isDraft: false, reviewDecision: "APPROVED", merge: "CLEAN", autoMerge: false)
        #expect(availableActions(approved) == [.merge, .enableAutoMerge, .convertToDraft, .close])
        let blocked = try detail(state: "OPEN", isDraft: false, reviewDecision: "APPROVED", merge: "BLOCKED", autoMerge: true)
        #expect(availableActions(blocked) == [.disableAutoMerge, .convertToDraft, .close])
        let unapproved = try detail(state: "OPEN", isDraft: false, reviewDecision: "REVIEW_REQUIRED", merge: "CLEAN", autoMerge: false)
        #expect(!availableActions(unapproved).contains(.merge))
        let draft = try detail(state: "OPEN", isDraft: true, reviewDecision: "", merge: "DRAFT", autoMerge: false)
        #expect(availableActions(draft) == [.markReady, .close])
        #expect(availableActions(try detail(state: "CLOSED", isDraft: false, reviewDecision: "", merge: "UNKNOWN", autoMerge: false)) == [.reopen])
        #expect(availableActions(try detail(state: "MERGED", isDraft: false, reviewDecision: "", merge: "UNKNOWN", autoMerge: false)).isEmpty)
    }

    @Test func pinsMergesToTheHeadTheOwnerSaw() {
        let ref = PullRequestRef(repo: "a/b", number: 3)
        #expect(ghArguments(for: .merge, of: ref, head: "abc") == ["pr", "merge", "3", "-R", "a/b", "--squash", "--delete-branch", "--match-head-commit", "abc"])
        #expect(ghArguments(for: .requestChanges, of: ref, body: "--admin") == ["pr", "review", "3", "-R", "a/b", "--request-changes", "--body", "--admin"])
    }

    @Test func ordersChecksAndHistory() throws {
        let pr = try detail(state: "OPEN", isDraft: false, reviewDecision: "", merge: "BLOCKED", autoMerge: false)
        #expect(pr.checks.map(\.title) == ["checks-python", "merge-approval", "guard"])
        #expect(!pr.isApproved)
        #expect(timeline(of: pr).map(\.actor) == ["owner", "owner", "owner"])
        #expect(timeline(of: pr).map(\.kind) == [.commit(sha: "ef42a30"), .review(state: "DISMISSED"), .comment])
    }

    @Test func splitsADiffIntoFiles() {
        let diff = """
            diff --git a/README.md b/README.md
            index d6b5539..410294a 100644
            --- a/README.md
            +++ b/README.md
            @@ -1,2 +1,3 @@
             # lab
            -old
            +new
            +--- not a header
            \\ No newline at end of file
            diff --git a/logo.png b/logo.png
            Binary files a/logo.png and b/logo.png differ
            """
        let files = parseUnifiedDiff(diff)
        #expect(files.map(\.path) == ["README.md", "logo.png"])
        #expect(files[0].lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .note])
        #expect((files[0].additions, files[0].deletions) == (2, 1))
        #expect(files[1].lines.map(\.kind) == [.note])
    }

    @Test func readsTheMarkdownOfPullRequestBodies() {
        let body = """
            ## What changes
            The discount code behaves
            exactly as before.

            - The percentage check no longer
              repeats range checks.
            * `invariant` helper
            1. first
            > quoted

            ```
            approve-head 10
            ```
            """
        #expect(markdownBlocks(body) == [
            .heading(level: 2, text: "What changes"),
            .paragraph("The discount code behaves exactly as before."),
            .bullet("The percentage check no longer repeats range checks."),
            .bullet("`invariant` helper"),
            .numbered(marker: "1.", text: "first"),
            .quote("quoted"),
            .code("approve-head 10"),
        ])
    }

    @Test func keepsACharacterCutBetweenTwoChunksWhole() {
        let text = Data("ok ş…".utf8)
        let (whole, rest) = splitAtLastWholeCharacter(text.dropLast(1))
        #expect(String(decoding: whole, as: UTF8.self) == "ok ş")
        #expect(rest.count == 2)
        #expect(splitAtLastWholeCharacter(text) == (text, Data()))
        #expect(String(decoding: rest + text.suffix(1), as: UTF8.self) == "…")
    }
}
