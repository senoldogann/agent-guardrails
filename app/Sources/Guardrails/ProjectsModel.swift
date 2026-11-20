import AppKit
import Foundation
import GuardrailsCore
import Observation

/// The Projects window's data: every repository of the owner with its state, and the open PRs of the one
/// selected. Loaded from `guardrails projects --json` and `guardrails prs <repo> --json`.
@MainActor
@Observable
final class ProjectsModel {
    private(set) var projects: [Project] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    private(set) var pullRequests: [String: PullRequestList] = [:]
    /// Why the open PRs of a repo could not be loaded, until a load succeeds.
    private(set) var pullRequestErrors: [String: String] = [:]
    /// A load asked for while one runs: it runs again afterwards, so it reads what an action just changed.
    private var loadsAgain = false
    /// Set-ups started from this app, by repo: shown as "Setting up…" until the bootstrap PR appears.
    private(set) var setupsStarted: [String: Date] = [:]
    /// The owner's agent App on this Mac, from `guardrails agent status --json`.
    private(set) var agent: AgentInfo?
    /// The Reports page's data.
    let reports: ReportsModel
    private let configuration: AppConfiguration

    struct PullRequestList: Equatable {
        let items: [PullRequestItem]
        let loaded: Date
    }

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        self.reports = ReportsModel(configuration: configuration)
    }

    func project(named repo: String) -> Project? {
        projects.first { sameRepository($0.repo, repo) }
    }

    func loadProjects() async {
        guard !isLoading else {
            loadsAgain = true
            return
        }
        isLoading = true
        defer {
            isLoading = false
            if loadsAgain {
                loadsAgain = false
                Task { await loadProjects() }
            }
        }
        do {
            let result = try await runGuardrails(["projects", "--json"])
            guard result.status == 0 else {
                lastError = describeCommandFailure(result, command: "guardrails projects")
                return
            }
            projects = try parseProjects(result.standardOutput)
            for project in projects where project.state != .off {
                setupsStarted[project.repo] = nil
            }
            let agentResult = try await runGuardrails(["agent", "status", "--json"])
            guard agentResult.status == 0 else {
                lastError = describeCommandFailure(agentResult, command: "guardrails agent status")
                return
            }
            agent = try parseAgentInfo(agentResult.standardOutput)
            lastError = nil
            lastUpdated = Date()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Loads the open PRs of a repo, reusing a list younger than a minute.
    func loadPullRequests(of repo: String) async {
        if let cached = pullRequests[listKey(repo)], Date().timeIntervalSince(cached.loaded) < 60 { return }
        await reloadPullRequests(of: repo)
    }

    /// Loads the open PRs of a repo from GitHub now.
    func reloadPullRequests(of repo: String) async {
        let key = listKey(repo)
        do {
            let result = try await runGuardrails(["prs", repo, "--json"])
            guard result.status == 0 else {
                pullRequestErrors[key] = describeCommandFailure(result, command: "guardrails prs \(repo)")
                return
            }
            pullRequests[key] = PullRequestList(items: try parsePullRequests(result.standardOutput), loaded: Date())
            pullRequestErrors[key] = nil
        } catch {
            pullRequestErrors[key] = String(describing: error)
        }
    }

    /// The key a repository's PR list is kept under: its name as the projects list spells it, so a name that came in
    /// another case (an alarm's, as the owner typed it) reaches the list the page reads.
    private func listKey(_ repo: String) -> String {
        project(named: repo)?.repo ?? repo
    }

    func markSetupStarted(_ repo: String) {
        setupsStarted[repo] = Date()
    }

    private func runGuardrails(_ arguments: [String]) async throws -> CommandResult {
        try await runCommand(
            command: ["/bin/bash", configuration.cliPath] + arguments,
            environment: cliEnvironment(inherited: ProcessInfo.processInfo.environment, eventsDescriptor: nil))
    }
}

/// The folder the owner keeps clones in. Chosen with an open panel and shown in the set-up sheet, so a
/// changed value is visible before anything runs in it.
enum ProjectsFolder {
    private static let key = "projectsFolder"

    static var current: String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func store(_ path: String) {
        UserDefaults.standard.set(path, forKey: key)
    }

    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "Choose the folder that holds your project clones."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        store(url.path)
        return url.path
    }
}

/// The steps of setting a project up: check or clone the local folder, then open Terminal with Claude.
@MainActor
@Observable
final class SetupModel {
    enum Step: Equatable {
        case needsFolder
        case checking
        case clone(CloneCheck)
        case cloning
        case launched
        case failed(String)
    }

    let project: Project
    private(set) var folder: String?
    private(set) var step = Step.needsFolder

    init(project: Project) {
        self.project = project
        self.folder = ProjectsFolder.current
    }

    var targetPath: String? {
        folder.map { clonePath(projectsFolder: $0, repo: project.repo) }
    }

    func chooseFolder() async {
        guard let chosen = ProjectsFolder.choose() else { return }
        folder = chosen
        await check()
    }

    func check() async {
        guard isValidRepoName(project.repo) else {
            step = .failed("\(project.repo) is not a repository name the app accepts.")
            return
        }
        guard let target = targetPath else {
            step = .needsFolder
            return
        }
        step = .checking
        step = .clone(await inspectClone(at: target, repo: project.repo, defaultBranch: project.branch))
    }

    func cloneRepository() async {
        guard let target = targetPath, isValidRepoName(project.repo) else { return }
        step = .cloning
        do {
            let result = try await runCommand(
                command: ["/usr/bin/env", "gh", "repo", "clone", project.repo, target],
                environment: cliEnvironment(inherited: ProcessInfo.processInfo.environment, eventsDescriptor: nil))
            guard result.status == 0 else {
                step = .failed("Cloning failed: \(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
                return
            }
            await check()
        } catch {
            step = .failed("Cloning failed: \(error)")
        }
    }

    /// Writes a one-off .command script and opens it in Terminal: Claude Code runs /guardrails-init there.
    func launchSetup() async {
        guard case .clone(.ready) = step, let target = targetPath else { return }
        do {
            let script = try writeSetupScript(clonePath: target, repo: project.repo)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                step = .failed("Terminal.app was not found.")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration)
            step = .launched
        } catch {
            step = .failed("Could not open Terminal: \(error.localizedDescription)")
        }
    }
}

/// Reads the facts about a clone without running code from it: origin from .git/config, status with
/// fsmonitor and hooks off, and the current branch.
private func inspectClone(at path: String, repo: String, defaultBranch: String) async -> CloneCheck {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
    guard isDirectory.boolValue else { return .problem("\(path) exists and is not a folder.") }
    let environment = cliEnvironment(inherited: ProcessInfo.processInfo.environment, eventsDescriptor: nil)
    let safeGit = ["/usr/bin/git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", path]
    do {
        let origin = try await runCommand(
            command: ["/usr/bin/git", "config", "--file", path + "/.git/config", "--get", "remote.origin.url"],
            environment: environment)
        let status = try await runCommand(
            command: safeGit + ["status", "--porcelain", "--untracked-files=all"], environment: environment)
        let branch = try await runCommand(command: safeGit + ["branch", "--show-current"], environment: environment)
        guard status.status == 0, branch.status == 0 else {
            return .problem("git could not read \(path): \(status.standardError)\(branch.standardError)")
        }
        return judgeClone(
            origin: origin.status == 0 ? origin.standardOutput : nil,
            statusPorcelain: status.standardOutput,
            branch: branch.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultBranch: defaultBranch,
            repo: repo)
    } catch {
        return .problem("Could not inspect \(path): \(error)")
    }
}

private func writeSetupScript(clonePath: String, repo: String) throws -> URL {
    let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appending(path: "Guardrails", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let name = repo.replacingOccurrences(of: "/", with: "-")
    let url = support.appending(path: "setup-\(name).command")
    try setupScript(clonePath: clonePath, repo: repo).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}
