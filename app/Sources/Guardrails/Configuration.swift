import Foundation

/// Where the kit install is. app/build.sh writes the kit path into Info.plist at build time, so the app
/// does not look the command up on PATH.
struct AppConfiguration: Sendable, Equatable {
    let kitPath: String

    var cliPath: String { kitPath + "/bin/guardrails" }

    enum LoadError: Error, CustomStringConvertible {
        case missingKey
        case missingCLI(String)

        var description: String {
            switch self {
            case .missingKey:
                "This build of Guardrails does not know where the kit is. Rebuild it with app/build.sh in the kit."
            case .missingCLI(let path):
                "The guardrails command is not at \(path). Rebuild the app with app/build.sh from the kit install."
            }
        }
    }

    static func fromMainBundle() -> Result<AppConfiguration, LoadError> {
        guard let kitPath = Bundle.main.object(forInfoDictionaryKey: "GuardrailsKitPath") as? String else {
            return .failure(.missingKey)
        }
        // A release build carries "~/.local/share/agent-guardrails"; a local build the absolute path of its kit.
        let configuration = AppConfiguration(kitPath: (kitPath as NSString).expandingTildeInPath)
        guard FileManager.default.isExecutableFile(atPath: configuration.cliPath) else {
            return .failure(.missingCLI(configuration.cliPath))
        }
        return .success(configuration)
    }
}

/// An action the owner started; it opens a review window.
struct ActionRequest: Codable, Hashable {
    enum Kind: String, Codable {
        case approve
        case turnOn
        case turnOnRepo
        case turnOff
        /// Fast-forward the kit install to its origin main, reinstall it and rebuild this app.
        case update
        /// Register the agent's own GitHub App in the browser.
        case agentCreate
    }

    let kind: Kind
    /// A PR link (approve, turnOn), owner/repo (turnOnRepo, turnOff), or "" (update, agentCreate).
    let target: String
    let label: String
    /// Every request is its own run: a window group brings back an open window for an equal value, which
    /// would show a finished or cancelled run instead of starting a new one.
    private(set) var run = UUID()

    var arguments: [String] {
        switch kind {
        case .approve: ["approve", target]
        case .turnOn, .turnOnRepo: ["on", target]
        case .turnOff: ["off", target]
        case .update: ["update"]
        case .agentCreate: ["agent", "create"]
        }
    }

    /// owner/repo of the target: taken from a PR link (https://github.com/<owner>/<repo>/pull/<n>) or used as is.
    var repo: String {
        let parts = target.split(separator: "/")
        if target.hasPrefix("https://github.com/"), parts.count >= 4 { return "\(parts[2])/\(parts[3])" }
        return target
    }

    var windowTitle: String {
        switch kind {
        case .approve: "Review and approve"
        case .turnOn, .turnOnRepo: "Turn guardrails on"
        case .turnOff: "Turn guardrails off"
        case .update: "Update the kit"
        case .agentCreate: "Create the agent's GitHub App"
        }
    }
}
