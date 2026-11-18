import Foundation

/// One check run on a commit, from `GET repos/{repo}/commits/{sha}/check-runs`.
public struct CheckRun: Codable, Sendable, Hashable, Identifiable {
    public struct App: Codable, Sendable, Hashable {
        public let slug: String
    }

    public let id: Int
    public let name: String
    /// queued, in_progress, completed, waiting, requested or pending.
    public let status: String
    /// Set once completed: success, failure, neutral, cancelled, skipped, timed_out, action_required or stale.
    public let conclusion: String?
    public let htmlURL: String
    public let startedAt: String?
    public let completedAt: String?
    public let app: App?

    public init(
        id: Int, name: String, status: String, conclusion: String?, htmlURL: String, startedAt: String?,
        completedAt: String?, app: App?
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.htmlURL = htmlURL
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.app = app
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, app
        case htmlURL = "html_url"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    public var outcome: CheckOutcome {
        guard status == "completed" else { return .running }
        switch conclusion {
        case "success": return .passed
        case "neutral", "skipped": return .skipped
        default: return .failed
        }
    }

    /// A kit gate job (`checks-<lang>`) run by GitHub Actions: its log holds the gate's steps.
    public var isKitGate: Bool { name.hasPrefix("checks-") && app?.slug == "github-actions" }

    /// Seconds from start to completion; nil while running or when GitHub sent no times.
    public var duration: TimeInterval? {
        let parse = ISO8601DateFormatter()
        guard let startedAt, let completedAt, let start = parse.date(from: startedAt),
            let end = parse.date(from: completedAt)
        else { return nil }
        return end.timeIntervalSince(start)
    }
}

/// "9s", "2m 5s": how long a check ran, in English like the rest of the app.
public func shortDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
}

public enum CheckOutcome: Int, Sendable, Comparable {
    case failed
    case running
    case passed
    case skipped

    public static func < (lhs: CheckOutcome, rhs: CheckOutcome) -> Bool { lhs.rawValue < rhs.rawValue }
}

private struct CheckRunsPage: Decodable {
    let checkRuns: [CheckRun]

    enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
    }
}

/// Parses the check-runs response and orders it for the owner: failed first, then running, passed, skipped.
public func parseCheckRuns(_ json: String) throws -> [CheckRun] {
    do {
        let page = try JSONDecoder().decode(CheckRunsPage.self, from: Data(json.utf8))
        return page.checkRuns.sorted { ($0.outcome, $0.name) < ($1.outcome, $1.name) }
    } catch {
        throw JSONLinesError(source: "GitHub check runs", lineNumber: 1, line: String(json.prefix(300)), reason: String(describing: error))
    }
}

/// What the CI run of one `checks-<lang>` job did, read from its log. The log also carries what the code under
/// test prints, so this is a reading aid: the check run's own result is what counts.
public struct GateReport: Sendable, Equatable {
    public let gates: [Gate]
    public let mutation: MutationOutcome

    public init(gates: [Gate], mutation: MutationOutcome) {
        self.gates = gates
        self.mutation = mutation
    }
}

/// One gate of `make ci` and the `make` targets it ran, in order.
public struct Gate: Sendable, Equatable {
    public let kind: GateKind
    public let steps: [GateStep]

    public init(kind: GateKind, steps: [GateStep]) {
        self.kind = kind
        self.steps = steps
    }
}

public enum GateKind: Sendable, Equatable {
    /// The PR adds a spec that is not locked yet.
    case draft(ticket: String)
    /// The locked tests must fail against the stubs at the spec-lock commit.
    case spec(ticket: String)
    /// Every check on the PR's head.
    case full
}

public struct GateStep: Sendable, Equatable {
    public let name: String
    /// nil when the log ends before the step's `[exit N]` line.
    public let exitCode: Int?

    public init(name: String, exitCode: Int?) {
        self.name = name
        self.exitCode = exitCode
    }

    public var passed: Bool { exitCode == 0 }
}

public enum MutationOutcome: Sendable, Equatable {
    /// The log has no mutation gate: the spec gate only, a failed full gate, or a language without one.
    case notRun
    /// The PR changes no source file the gate mutates.
    case nothingToMutate
    case judged(MutationCounts)
    /// The gate started on changed files but the log has no verdict.
    case unfinished
}

/// The `mutation-gate` verdict line: `mutants: K killed, A accepted, I invalid, F failing`.
public struct MutationCounts: Sendable, Equatable {
    public let killed: Int
    public let accepted: Int
    public let invalid: Int
    public let failing: Int

    public init(killed: Int, accepted: Int, invalid: Int, failing: Int) {
        self.killed = killed
        self.accepted = accepted
        self.invalid = invalid
        self.failing = failing
    }

    /// Mutants that count toward the score: invalid ones are listed but not counted.
    public var counted: Int { killed + accepted + failing }
}

/// Reads a GitHub Actions job log of `make ci`: timestamps and color codes are dropped, then the kit's frame
/// lines (`=== … gate …`, `$ make <target>`, `[exit N]`, `mutation scope:`, `mutants:`) are collected.
/// The last verdict line wins, as `mutation-gate` prints it after everything the tests printed.
public func parseGateLog(_ log: String) -> GateReport {
    var gates: [Gate] = []
    var kind: GateKind?
    var steps: [GateStep] = []
    var mutationStarted = false
    var scopeIsEmpty = false
    var counts: MutationCounts?

    func closeGate() {
        if let kind { gates.append(Gate(kind: kind, steps: steps)) }
        kind = nil
        steps = []
    }

    for raw in log.split(whereSeparator: \.isNewline) {
        let line = plainLogLine(String(raw))
        if let gate = gateKind(line) {
            closeGate()
            kind = gate
            mutationStarted = false
        } else if line.hasPrefix("=== mutation gate for ") {
            closeGate()
            mutationStarted = true
        } else if kind != nil, line.hasPrefix("$ make "), let target = line.split(separator: " ").dropFirst(2).first {
            steps.append(GateStep(name: String(target), exitCode: nil))
        } else if kind != nil, let code = exitCode(line), let last = steps.last, last.exitCode == nil {
            steps[steps.count - 1] = GateStep(name: last.name, exitCode: code)
        } else if mutationStarted, line.hasPrefix("mutation scope: ") {
            scopeIsEmpty = line.hasPrefix("mutation scope: 0 ")
        } else if mutationStarted, let parsed = mutationCounts(line) {
            counts = parsed
        }
    }
    closeGate()

    let mutation: MutationOutcome
    if let counts {
        mutation = .judged(counts)
    } else if mutationStarted {
        mutation = scopeIsEmpty ? .nothingToMutate : .unfinished
    } else {
        mutation = .notRun
    }
    return GateReport(gates: gates, mutation: mutation)
}

/// Drops the `2026-11-17T10:54:01.0765295Z ` prefix GitHub adds and ANSI color codes.
private func plainLogLine(_ line: String) -> String {
    let withoutColor = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    return withoutColor.replacingOccurrences(
        of: "^\\d{4}-\\d{2}-\\d{2}T[0-9:.]+Z ", with: "", options: .regularExpression)
}

private func gateKind(_ line: String) -> GateKind? {
    if line.hasPrefix("=== full gate at ") { return .full }
    if let ticket = word(after: "=== spec gate for ", in: line) { return .spec(ticket: ticket) }
    if let ticket = word(after: "=== draft gate for ", in: line) { return .draft(ticket: ticket) }
    return nil
}

private func word(after prefix: String, in line: String) -> String? {
    guard line.hasPrefix(prefix) else { return nil }
    return line.dropFirst(prefix.count).split(separator: " ").first.map(String.init)
}

private func exitCode(_ line: String) -> Int? {
    guard line.hasPrefix("[exit "), line.hasSuffix("]") else { return nil }
    return Int(line.dropFirst("[exit ".count).dropLast())
}

private func mutationCounts(_ line: String) -> MutationCounts? {
    let pattern = /^mutants: (\d+) killed, (\d+) accepted, (\d+) invalid, (\d+) failing$/
    guard let match = line.wholeMatch(of: pattern), let killed = Int(match.1), let accepted = Int(match.2),
        let invalid = Int(match.3), let failing = Int(match.4)
    else { return nil }
    return MutationCounts(killed: killed, accepted: accepted, invalid: invalid, failing: failing)
}

/// The ticket whose spec a PR carries: the `<ID>` of the first `specs/<ID>/` file it changes, when `<ID>`
/// looks like a kit ticket id (ABC-123).
public func ticketID(changing files: [PlannedFile]) -> String? {
    for file in files {
        let parts = file.path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "specs" else { continue }
        let id = String(parts[1])
        if id.wholeMatch(of: /[A-Za-z][A-Za-z0-9]*-[0-9]+/) != nil { return id }
    }
    return nil
}

/// The size of a PR's change, from `GET repos/{repo}/pulls/{number}`.
public struct DiffStats: Codable, Sendable, Equatable {
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int

    public init(additions: Int, deletions: Int, changedFiles: Int) {
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
    }

    enum CodingKeys: String, CodingKey {
        case additions, deletions
        case changedFiles = "changed_files"
    }
}

public func parseDiffStats(_ json: String) throws -> DiffStats {
    do {
        return try JSONDecoder().decode(DiffStats.self, from: Data(json.utf8))
    } catch {
        throw JSONLinesError(source: "GitHub pull request", lineNumber: 1, line: String(json.prefix(300)), reason: String(describing: error))
    }
}
