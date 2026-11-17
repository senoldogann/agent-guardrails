import Foundation

/// The owner/repo pattern the CLI accepts; anything else never reaches a path or a command.
public func isValidRepoName(_ repo: String) -> Bool {
    repo.wholeMatch(of: /[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+/) != nil && !repo.contains("..")
}

/// Where the local clone of a repo is expected: <projects folder>/<repo name>.
public func clonePath(projectsFolder: String, repo: String) -> String {
    let name = repo.split(separator: "/").last.map(String.init) ?? repo
    return (projectsFolder as NSString).appendingPathComponent(name)
}

/// Whether a git remote URL points at github.com/<repo> (https or ssh, with or without .git).
public func originMatches(_ url: String, repo: String) -> Bool {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidates = [
        "https://github.com/\(repo)", "https://github.com/\(repo).git",
        "git@github.com:\(repo)", "git@github.com:\(repo).git",
        "ssh://git@github.com/\(repo)", "ssh://git@github.com/\(repo).git",
    ]
    return candidates.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
}

/// Single-quotes a string for a POSIX shell.
public func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The script Terminal runs to start the set-up: Claude Code with /guardrails-init in the clone, interactive,
/// with its normal permission prompts so the owner watches what it does.
public func setupScript(clonePath: String, repo: String) -> String {
    """
    #!/bin/bash
    cd -- \(shellQuote(clonePath)) || exit 1
    printf '%s\\n' \(shellQuote("Setting up agent guardrails in \(repo). Claude runs /guardrails-init and opens a bootstrap PR; it then shows up in Guardrails as Ready to turn on."))
    exec claude '/guardrails-init'

    """
}

/// What the app found at the expected clone path.
public enum CloneCheck: Equatable, Sendable {
    case missing
    case ready
    case problem(String)
}

/// Judges a local folder from facts read without running repository code: the origin URL from .git/config,
/// `git status --porcelain` with fsmonitor and hooks off, and the current branch.
public func judgeClone(origin: String?, statusPorcelain: String, branch: String, defaultBranch: String, repo: String)
    -> CloneCheck
{
    guard let origin else { return .problem("The folder is not a git clone with an origin remote.") }
    guard originMatches(origin, repo: repo) else {
        return .problem("The folder's origin is \(origin), not github.com/\(repo).")
    }
    guard statusPorcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .problem("The clone has uncommitted changes. Commit or stash them first, so the bootstrap PR holds only the kit.")
    }
    guard branch == defaultBranch else {
        return .problem("The clone is on \(branch). Switch it to \(defaultBranch) first.")
    }
    return .ready
}
