import Foundation
import GuardrailsCore
import Observation

/// A value the Review window loads from GitHub on its own, next to the CLI's plan.
enum Loadable<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case failed(String)

    var isLoaded: Bool {
        if case .loaded = self { true } else { false }
    }
}

/// The spec a PR carries, as committed at the commit the owner approves.
struct SpecDocuments: Equatable {
    let ticket: String
    let url: String
    /// nil when the file is not in the PR's tree.
    let acceptanceCriteria: String?
    let properties: String?
}

/// What the owner looks at before approving, read from GitHub with the owner's gh at exactly the planned
/// commit: the size of the change, every check run, what each kit gate ran (from its CI log), and the spec.
/// Read-only and for reading: the CLI's plan and the checks' own results decide.
@MainActor
@Observable
final class PullRequestEvidence {
    private(set) var snapshot: Loadable<PullRequestSnapshot> = .loading
    private(set) var checks: Loadable<[CheckRun]> = .loading
    /// By check run id.
    private(set) var gates: [Int: Loadable<GateReport>] = [:]
    /// nil when the PR changes no `specs/<ID>/`.
    private(set) var spec: Loadable<SpecDocuments>?
    private(set) var isLoading = false

    func load(_ pr: PullRequestPlan) async {
        guard isValidRepoName(pr.repo), pr.sha.wholeMatch(of: /[0-9a-f]{40}/) != nil else {
            let problem = "The plan names \(pr.repo) at \(pr.sha), which the app does not read from GitHub."
            snapshot = .failed(problem)
            checks = .failed(problem)
            return
        }
        isLoading = true
        defer { isLoading = false }
        async let diffDone: Void = loadDiff(pr)
        async let checksDone: Void = loadChecks(pr)
        async let specDone: Void = loadSpec(pr)
        _ = await (diffDone, checksDone, specDone)
    }

    private func loadDiff(_ pr: PullRequestPlan) async {
        do {
            snapshot = .loaded(try parsePullRequestSnapshot(try await readGitHub(["api", "repos/\(pr.repo)/pulls/\(pr.pr)"])))
        } catch {
            snapshot = .failed(String(describing: error))
        }
    }

    private func loadChecks(_ pr: PullRequestPlan) async {
        let runs: [CheckRun]
        do {
            runs = try parseCheckRuns(
                try await readGitHub([
                    "api", "--paginate", "repos/\(pr.repo)/commits/\(pr.sha)/check-runs?per_page=100", "--jq", ".check_runs[]",
                ]))
            checks = .loaded(runs)
        } catch {
            checks = .failed(String(describing: error))
            return
        }
        for run in runs where run.isKitGate {
            guard run.outcome != .running else {
                gates[run.id] = nil
                continue
            }
            gates[run.id] = .loading
            do {
                // The log is plain text with the color codes CI printed; gh refuses those without the flag.
                let log = try await readGitHub(["api", "repos/\(pr.repo)/actions/jobs/\(run.id)/logs", "--allow-escape-sequences"])
                gates[run.id] = .loaded(parseGateLog(log))
            } catch {
                gates[run.id] = .failed(String(describing: error))
            }
        }
    }

    private func loadSpec(_ pr: PullRequestPlan) async {
        guard let ticket = ticketID(changing: pr.files) else {
            spec = nil
            return
        }
        spec = .loading
        do {
            let criteria = try await readSpecFile(pr, ticket: ticket, name: "acceptance-criteria.md")
            let properties = try await readSpecFile(pr, ticket: ticket, name: "properties.md")
            spec = .loaded(
                SpecDocuments(
                    ticket: ticket, url: "https://github.com/\(pr.repo)/tree/\(pr.sha)/specs/\(ticket)",
                    acceptanceCriteria: criteria.map(displaySafe), properties: properties.map(displaySafe)))
        } catch {
            spec = .failed(String(describing: error))
        }
    }

    /// A spec file at the planned commit; nil when the PR's tree has no such file.
    private func readSpecFile(_ pr: PullRequestPlan, ticket: String, name: String) async throws -> String? {
        do {
            return try await readGitHub([
                "api", "repos/\(pr.repo)/contents/specs/\(ticket)/\(name)?ref=\(pr.sha)",
                "-H", "Accept: application/vnd.github.raw+json",
            ])
        } catch let error as GitHubCommandError where error.isNotFound {
            return nil
        }
    }
}

/// A gh call that failed, with what it asked for and what GitHub answered.
struct GitHubCommandError: Error, CustomStringConvertible {
    let arguments: [String]
    let status: Int32
    let message: String

    var isNotFound: Bool { message.contains("HTTP 404") }
    /// GitHub refused the request itself (not found, no access, invalid): asking again cannot change that.
    var isClientError: Bool { message.range(of: #"HTTP 4\d\d"#, options: .regularExpression) != nil }
    var description: String { "gh \(arguments.joined(separator: " ")) exited with \(status): \(message)" }
}

/// Runs a read-only gh command with the owner's login. A failure other than GitHub refusing the request (4xx) is tried again
/// with a growing pause, each attempt logged, and the last error is raised.
func readGitHub(_ arguments: [String]) async throws -> String {
    let attempts = 3
    var attempt = 1
    while true {
        let result = try await runCommand(
            command: ["/usr/bin/env", "gh"] + arguments,
            environment: cliEnvironment(inherited: ProcessInfo.processInfo.environment, eventsDescriptor: nil))
        if result.status == 0 { return result.standardOutput }
        let error = GitHubCommandError(
            arguments: arguments, status: result.status,
            message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !error.isClientError, attempt < attempts else { throw error }
        NSLog("Guardrails: GitHub read failed, attempt %d of %d: %@", attempt, attempts, error.description)
        try await Task.sleep(for: .seconds(attempt * 2))
        attempt += 1
    }
}
