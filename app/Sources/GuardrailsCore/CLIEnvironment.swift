import Foundation

/// Where the owner's tools live; a GUI app does not get the login shell's PATH.
public let cliSearchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

/// The environment the app gives the guardrails CLI: an allowlist, never the app's own environment.
/// Variables set with `launchctl setenv` (BASH_ENV, GH_TOKEN, GH_CONFIG_DIR, GIT_CONFIG_GLOBAL, ...) would
/// otherwise reach the CLI and change what it runs or which account it uses.
public func cliEnvironment(inherited: [String: String], eventsDescriptor: Int32?) -> [String: String] {
    var environment: [String: String] = [
        "PATH": cliSearchPath,
        "LANG": "en_US.UTF-8",
        "TERM": "dumb",
        "NO_COLOR": "1",
        "GH_PAGER": "cat",
        "GH_NO_UPDATE_NOTIFIER": "1",
    ]
    for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"] {
        if let value = inherited[key] { environment[key] = value }
    }
    if let eventsDescriptor { environment["GUARDRAILS_EVENTS_FD"] = String(eventsDescriptor) }
    return environment
}

/// How the app starts the CLI for an action: inside a pseudo-terminal made by script(1), so the CLI's
/// interactive-terminal check and its typed confirmations work unchanged.
public func terminalCommand(cliPath: String, arguments: [String]) -> [String] {
    ["/usr/bin/script", "-q", "/dev/null", "/bin/bash", cliPath] + arguments
}
