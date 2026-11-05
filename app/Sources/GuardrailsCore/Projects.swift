import Foundation

/// A repository's state as `guardrails projects --json` reports it.
public enum ProjectState: String, Codable, Sendable, CaseIterable {
    case alarm
    case on
    case ready
    case off
    case noAdmin = "no-admin"
}

/// One line of `guardrails projects --json`.
public struct Project: Codable, Sendable, Hashable, Identifiable {
    public let repo: String
    public let state: ProjectState
    public let note: String
    public let `private`: Bool
    public let fork: Bool
    public let branch: String
    public let pushed: String
    public let openPRs: Int
    public let setupURL: String
    public let setupTitle: String

    public init(
        repo: String, state: ProjectState, note: String, private: Bool, fork: Bool, branch: String, pushed: String,
        openPRs: Int,
        setupURL: String, setupTitle: String
    ) {
        self.repo = repo
        self.state = state
        self.note = note
        self.private = `private`
        self.fork = fork
        self.branch = branch
        self.pushed = pushed
        self.openPRs = openPRs
        self.setupURL = setupURL
        self.setupTitle = setupTitle
    }

    public var id: String { repo }
    public var name: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

/// Projects grouped for the sidebar: what needs the owner first, then on, ready to turn on, and the rest.
public struct ProjectGroups: Sendable, Equatable {
    public let needsYou: [Project]
    public let on: [Project]
    public let ready: [Project]
    public let off: [Project]
}

public struct JSONLinesError: Error, CustomStringConvertible {
    public let source: String
    public let lineNumber: Int
    public let line: String
    public let reason: String

    public var description: String { "\(source) line \(lineNumber) is not valid (\(reason)): \(line)" }
}

/// Decodes one JSON object per line.
public func decodeJSONLines<Item: Decodable>(_ output: String, as type: Item.Type, source: String) throws -> [Item] {
    let decoder = JSONDecoder()
    return try output.split(whereSeparator: \.isNewline).enumerated().map { index, line in
        do {
            return try decoder.decode(type, from: Data(line.utf8))
        } catch {
            throw JSONLinesError(source: source, lineNumber: index + 1, line: String(line), reason: String(describing: error))
        }
    }
}

public func parseProjects(_ output: String) throws -> [Project] {
    try decodeJSONLines(output, as: Project.self, source: "guardrails projects")
}

/// Filters by a search text (case-insensitive, on owner/repo) and groups; the CLI's order (newest push) stays.
public func groupProjects(_ projects: [Project], matching search: String) -> ProjectGroups {
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    let shown = needle.isEmpty ? projects : projects.filter { $0.repo.lowercased().contains(needle) }
    return ProjectGroups(
        needsYou: shown.filter { $0.state == .alarm },
        on: shown.filter { $0.state == .on },
        ready: shown.filter { $0.state == .ready },
        off: shown.filter { $0.state == .off || $0.state == .noAdmin })
}

/// The state of one open PR as `guardrails prs <repo> --json` reports it.
public enum PullRequestKind: String, Codable, Sendable {
    case answer
    case approve
    case wait
    case blocked
    case draft
    case approved
}

/// One line of `guardrails prs <repo> --json`.
public struct PullRequestItem: Codable, Sendable, Hashable, Identifiable {
    public let number: Int
    public let url: String
    public let title: String
    public let kind: PullRequestKind
    public let note: String
    public let sha: String
    public let draft: Bool
    public let author: String
    public let updated: String

    public var id: Int { number }
}

public func parsePullRequests(_ output: String) throws -> [PullRequestItem] {
    try decodeJSONLines(output, as: PullRequestItem.self, source: "guardrails prs")
}

/// Removes invisible format characters (bidirectional overrides, zero-width joiners and spaces) from text an
/// agent wrote, so a title cannot render differently from what it says.
public func displaySafe(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
}
