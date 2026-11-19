import Foundation
import Testing

@testable import GuardrailsCore

@Suite("projects")
struct ProjectsTests {
    private let output = """
        {"repo":"acme/shop","state":"on","note":"ruleset active","private":true,"fork":false,"branch":"main","pushed":"2026-11-05T10:00:00Z","openPRs":3,"setupURL":"","setupTitle":""}
        {"repo":"acme/billing","state":"alarm","note":"ruleset disabled","private":true,"fork":false,"branch":"main","pushed":"2026-11-04T10:00:00Z","openPRs":0,"setupURL":"","setupTitle":""}
        {"repo":"acme/mobile","state":"ready","note":"bootstrap PR open","private":false,"fork":false,"branch":"main","pushed":"2026-11-03T10:00:00Z","openPRs":1,"setupURL":"https://github.com/acme/mobile/pull/2","setupTitle":"chore: install"}
        {"repo":"acme/site","state":"off","note":"","private":false,"fork":false,"branch":"main","pushed":"2026-11-02T10:00:00Z","openPRs":0,"setupURL":"","setupTitle":""}
        {"repo":"acme/teammate","state":"elsewhere","note":"enforced from another Mac","private":true,"fork":false,"branch":"main","pushed":"2026-11-01T11:00:00Z","openPRs":2,"setupURL":"","setupTitle":""}
        {"repo":"acme/vendored","state":"no-admin","note":"","private":false,"fork":true,"branch":"main","pushed":"2026-11-01T10:00:00Z","openPRs":0,"setupURL":"","setupTitle":""}
        """

    @Test func groupsByWhatTheOwnerDoes() throws {
        let groups = groupProjects(try parseProjects(output), matching: "")
        #expect(groups.needsYou.map(\.repo) == ["acme/billing"])
        #expect(groups.on.map(\.repo) == ["acme/shop"])
        #expect(groups.ready.map(\.setupURL) == ["https://github.com/acme/mobile/pull/2"])
        #expect(groups.elsewhere.map(\.repo) == ["acme/teammate"])
        #expect(groups.off.map(\.repo) == ["acme/site", "acme/vendored"])
    }

    @Test func readsModeAndAgentAppWhenPresent() throws {
        let projects = try parseProjects("""
            {"repo":"acme/a","state":"on","note":"","private":true,"fork":false,"branch":"main","pushed":"","openPRs":0,"setupURL":"","setupTitle":"","mode":"status","agentApp":"installed"}
            {"repo":"acme/b","state":"on","note":"","private":true,"fork":false,"branch":"main","pushed":"","openPRs":0,"setupURL":"","setupTitle":"","mode":"review","agentApp":"installed"}
            {"repo":"acme/c","state":"off","note":"","private":true,"fork":false,"branch":"main","pushed":"","openPRs":0,"setupURL":"","setupTitle":"","mode":null,"agentApp":"none"}
            """)
        #expect(projects.map(\.canSwitchToReviewMode) == [true, false, false])
        #expect(projects.map(\.mode) == [.status, .review, nil])
        #expect(try parseProjects(output).allSatisfy { $0.mode == nil && $0.agentApp == nil })
    }

    @Test func offersTheMergeQueueOnlyToOrganizationsInReviewMode() throws {
        let projects = try parseProjects("""
            {"repo":"acme/a","state":"on","note":"","private":true,"fork":false,"branch":"main","pushed":"","openPRs":0,"setupURL":"","setupTitle":"","mode":"review","agentApp":"installed","mergeQueue":false,"organization":true}
            {"repo":"acme/b","state":"on","note":"","private":true,"fork":false,"branch":"main","pushed":"","openPRs":0,"setupURL":"","setupTitle":"","mode":"review","agentApp":"installed","mergeQueue":true,"organization":true}
            {"repo":"acme/c","state":"on","note":"","private":true,"fork":false,"branch":"main","pushed":"","openPRs":0,"setupURL":"","setupTitle":"","mode":"status","agentApp":"installed","mergeQueue":false,"organization":true}
            {"repo":"me/d","state":"on","note":"","private":true,"fork":false,"branch":"main","pushed":"","openPRs":0,"setupURL":"","setupTitle":"","mode":"review","agentApp":"installed","mergeQueue":false,"organization":false}
            """)
        #expect(projects.map(\.canTurnOnMergeQueue) == [true, false, false, false])
        #expect(projects.map(\.mergeQueue) == [false, true, false, false])
        #expect(try parseProjects(output).allSatisfy { $0.mergeQueue == nil && !$0.canTurnOnMergeQueue })
    }

    @Test func saysWhyARepositoryNeedsTheOwner() throws {
        let byRepo = Dictionary(uniqueKeysWithValues: try parseProjects(output).map { ($0.repo, $0) })
        let line = { (repo: String, waiting: Int) in attentionLine(for: byRepo[repo]!, waiting: waiting) }
        #expect(line("acme/billing", 0) == "ruleset disabled")
        #expect(line("acme/mobile", 0) == "Bootstrap PR is ready to turn on")
        #expect(line("acme/shop", 0) == nil)
        #expect(line("acme/shop", 1) == "1 waits for you")
        #expect(line("acme/shop", 2) == "2 wait for you")
        #expect(line("acme/site", 4) == nil)
        #expect(line("acme/teammate", 0) == nil)
    }

    @Test func searchMatchesOwnerAndName() throws {
        let groups = groupProjects(try parseProjects(output), matching: " SHO ")
        #expect(groups.on.map(\.repo) == ["acme/shop"])
        #expect(groups.off.isEmpty && groups.ready.isEmpty && groups.needsYou.isEmpty && groups.elsewhere.isEmpty)
    }

    @Test func parsesPullRequestKinds() throws {
        let items = try parsePullRequests(
            #"{"number":7,"url":"u","title":"feat: x","kind":"draft","note":"n","sha":"abc","draft":true,"author":"o","updated":"t"}"#)
        #expect(items.map(\.kind) == [.draft])
        let queued = try parsePullRequests(
            #"{"number":8,"url":"u","title":"feat: y","kind":"queued","note":"n","sha":"abc","draft":false,"author":"o","updated":"t"}"#)
        #expect(queued.map(\.kind) == [.queued])
        #expect(throws: JSONLinesError.self) {
            try parsePullRequests(#"{"number":7,"url":"u","title":"x","kind":"merged","note":"","sha":"","draft":false,"author":"","updated":""}"#)
        }
    }

    @Test func dropsInvisibleFormatCharacters() {
        #expect(displaySafe("fix\u{202E}txt.exe\u{200B}") == "fixtxt.exe")
    }
}

@Suite("set up")
struct SetupTests {
    @Test func acceptsOnlyPlainRepoNames() {
        #expect(isValidRepoName("acme/shop-app.v2"))
        #expect(!isValidRepoName("acme/../etc"))
        #expect(!isValidRepoName("acme/shop; rm -rf ~"))
        #expect(!isValidRepoName("acme"))
    }

    @Test func matchesOriginsOfTheRepoOnly() {
        #expect(originMatches("https://github.com/acme/shop.git\n", repo: "acme/shop"))
        #expect(originMatches("git@github.com:Acme/Shop", repo: "acme/shop"))
        #expect(!originMatches("https://github.com/evil/shop.git", repo: "acme/shop"))
        #expect(!originMatches("https://github.com/acme/shop-fork.git", repo: "acme/shop"))
    }

    @Test func judgesAClone() {
        #expect(judgeClone(origin: "https://github.com/acme/shop", statusPorcelain: "", branch: "main", defaultBranch: "main", repo: "acme/shop") == .ready)
        #expect(judgeClone(origin: nil, statusPorcelain: "", branch: "main", defaultBranch: "main", repo: "acme/shop") != .ready)
        #expect(judgeClone(origin: "https://github.com/acme/shop", statusPorcelain: "?? x\n", branch: "main", defaultBranch: "main", repo: "acme/shop") != .ready)
        #expect(judgeClone(origin: "https://github.com/acme/shop", statusPorcelain: "", branch: "feat/x", defaultBranch: "main", repo: "acme/shop") != .ready)
    }

    @Test func quotesTheCloneInTheTerminalScript() throws {
        let script = setupScript(clonePath: "/Users/o/my projects/it's", repo: "acme/shop")
        #expect(script.contains("cd -- '/Users/o/my projects/it'\\''s' || exit 1"))
        #expect(script.contains("exec claude '/guardrails-init'"))
        #expect(!script.contains("dangerously"))
    }
}
