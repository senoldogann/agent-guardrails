import Foundation

/// The windows the Reports page offers, in days.
public enum ReportWindow: Int, CaseIterable, Identifiable, Sendable {
    case week = 7
    case month = 30
    case quarter = 90

    public var id: Int { rawValue }
    public var title: String { "\(rawValue) days" }
}

/// Seconds from ready for review to an event, over the PRs merged in the window; nil without any PR.
public struct DurationStats: Codable, Sendable, Equatable {
    public let count: Int
    public let median: Int?
    public let p90: Int?

    public init(count: Int, median: Int?, p90: Int?) {
        self.count = count
        self.median = median
        self.p90 = p90
    }
}

/// Merged PRs by author: the agent App's bot, people, other bots (dependabot and the like).
public struct MergedCounts: Codable, Sendable, Equatable {
    public let total: Int
    public let agent: Int
    public let people: Int
    public let otherBots: Int
}

/// A PR merged without an approval on its final commit: an admin bypassed the review rule, it merged before the
/// guardrails were on, or the only approval was of an earlier commit.
public struct AdminMerge: Codable, Sendable, Hashable, Identifiable {
    public let number: Int
    public let title: String
    public let url: String
    public let mergedBy: String
    public let mergedAt: String

    public var id: Int { number }
}

/// One saved version of a ruleset in the window: when, by whom, and what differs from the version before it.
public struct RulesetChange: Codable, Sendable, Hashable {
    public let time: String
    public let actor: String
    public let ruleset: String
    public let changes: [String]
}

/// One line of `guardrails report --json`: how agent work went in one repository over the window.
public struct RepoReport: Codable, Sendable, Equatable, Identifiable {
    public let repo: String
    public let days: Int
    public let since: String
    /// PRs open at some time in the window.
    public let prs: Int
    public let merged: MergedCounts
    public let approve: DurationStats
    public let merge: DurationStats
    public let reapproved: Int
    public let guardFailed: Int
    public let checksFailed: Int
    public let failed: Int
    public let failedThenMerged: Int
    public let adminMerges: [AdminMerge]
    /// PRs with more commits or events than the CLI reads; their numbers can be short.
    public let partial: [Int]
    public let rulesetChanges: [RulesetChange]

    public var id: String { repo }
}

public func parseReports(_ output: String) throws -> [RepoReport] {
    try decodeJSONLines(output, as: RepoReport.self, source: "guardrails report")
}

/// "45 s", "12 min", "3.5 h", "2.1 days": a duration as the CLI's text report writes it.
public func formatSpan(seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) s" }
    if seconds < 3600 { return "\(seconds / 60) min" }
    if seconds < 172_800 { return "\(oneDecimal(Double(seconds) / 3600)) h" }
    return "\(oneDecimal(Double(seconds) / 86400)) days"
}

/// Rounded down to one decimal, without a trailing ".0".
private func oneDecimal(_ value: Double) -> String {
    let tenths = Int((value * 10).rounded(.down))
    return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
}

private func pullRequests(_ count: Int) -> String {
    count == 1 ? "1 pull request" : "\(count) pull requests"
}

/// "3 merged: 2 by the agent App, 1 by people".
public func mergedSentence(_ report: RepoReport) -> String {
    let merged = report.merged
    guard merged.total > 0 else { return "None merged" }
    var parts = ["\(merged.agent) by the agent App", "\(merged.people) by people"]
    if merged.otherBots > 0 { parts.append("\(merged.otherBots) by other bots") }
    return "\(merged.total) merged: " + parts.joined(separator: ", ")
}

/// "Median 1 h, 90th percentile 2 h, over 2 pull requests", or what is missing.
public func durationSentence(_ stats: DurationStats, none: String) -> String {
    guard stats.count > 0, let median = stats.median, let p90 = stats.p90 else { return none }
    return "Median \(formatSpan(seconds: median)), 90th percentile \(formatSpan(seconds: p90)), over \(pullRequests(stats.count))"
}

public func reapprovalSentence(_ report: RepoReport) -> String {
    switch report.reapproved {
    case 0: "None needed a new approval after a push"
    case 1: "1 pull request needed a new approval after a push"
    default: "\(report.reapproved) pull requests needed a new approval after a push"
    }
}

/// "2 pull requests had a failing run (guard 1, checks 1); 1 merged after a later green run".
public func checksSentence(_ report: RepoReport) -> String {
    guard report.failed > 0 else { return "No failing guard or checks run" }
    return "\(pullRequests(report.failed)) had a failing run (guard \(report.guardFailed), checks \(report.checksFailed)); "
        + "\(report.failedThenMerged) merged after a later green run"
}

public func adminMergeSentence(_ report: RepoReport) -> String {
    switch report.adminMerges.count {
    case 0: "Every merge had an approval on its final commit"
    case 1: "1 merged without an approval on its final commit"
    default: "\(report.adminMerges.count) merged without an approval on their final commit"
    }
}
