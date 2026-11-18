import Foundation

/// The kind of one line of `guardrails inbox --json`.
public enum InboxKind: String, Codable, Sendable {
    case alarm
    case note
    case repo
    case answer
    case approve
    case wait
    case blocked
    case turnOn = "turn-on"
}

/// One line of `guardrails inbox --json`. Titles are written by the agent; the CLI strips control characters.
public struct InboxItem: Codable, Sendable, Hashable, Identifiable {
    public let kind: InboxKind
    public let repo: String
    public let url: String
    public let title: String
    public let note: String

    public init(kind: InboxKind, repo: String, url: String, title: String, note: String) {
        self.kind = kind
        self.repo = repo
        self.url = url
        self.title = title
        self.note = note
    }

    public var id: String { [kind.rawValue, repo, url, note].joined(separator: "|") }
}

/// A repository the owner enforces, with the state of its `agent-guardrails` ruleset.
public struct EnforcedRepo: Sendable, Hashable, Identifiable {
    public let name: String
    public let rulesetState: String

    public var id: String { name }
}

/// The inbox grouped the way the app shows it.
public struct InboxSnapshot: Sendable, Equatable {
    public let alarms: [InboxItem]
    public let notes: [InboxItem]
    public let repos: [EnforcedRepo]
    public let approvals: [InboxItem]
    public let turnOns: [InboxItem]
    public let answers: [InboxItem]
    public let inProgress: [InboxItem]

    public static let empty = InboxSnapshot(
        alarms: [], notes: [], repos: [], approvals: [], turnOns: [], answers: [], inProgress: [])

    /// An alarm without a repository concerns the kit install itself; on, off and approve refuse until it is fixed.
    public var hasKitInstallAlarm: Bool { alarms.contains { $0.repo.isEmpty } }
    public var isQuiet: Bool { alarms.isEmpty && approvals.isEmpty && turnOns.isEmpty && answers.isEmpty }
}

public struct InboxParseError: Error, CustomStringConvertible {
    public let lineNumber: Int
    public let line: String
    public let reason: String

    public var description: String { "inbox line \(lineNumber) is not valid (\(reason)): \(line)" }
}

/// Parses the output of `guardrails inbox --json`: one JSON object per line.
public func parseInbox(_ output: String) throws -> InboxSnapshot {
    let decoder = JSONDecoder()
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    let items: [InboxItem] = try lines.enumerated().map { index, line in
        do {
            return try decoder.decode(InboxItem.self, from: Data(line.utf8))
        } catch {
            throw InboxParseError(lineNumber: index + 1, line: line, reason: String(describing: error))
        }
    }
    return groupInbox(items)
}

/// Groups inbox items by what the owner does with them.
public func groupInbox(_ items: [InboxItem]) -> InboxSnapshot {
    func of(_ kinds: Set<InboxKind>) -> [InboxItem] { items.filter { kinds.contains($0.kind) } }
    return InboxSnapshot(
        alarms: of([.alarm]),
        notes: of([.note]),
        repos: of([.repo]).map { EnforcedRepo(name: $0.repo, rulesetState: $0.note) },
        approvals: of([.approve]),
        turnOns: of([.turnOn]),
        answers: of([.answer]),
        inProgress: of([.wait, .blocked]))
}

/// Alarms, approvals and the agent's questions that were not in the previous snapshot, for notifications.
public func newAttentionItems(previous: InboxSnapshot, current: InboxSnapshot) -> [InboxItem] {
    let known = Set(attentionItems(previous).map(\.id))
    return attentionItems(current).filter { !known.contains($0.id) }
}

private func attentionItems(_ snapshot: InboxSnapshot) -> [InboxItem] {
    snapshot.alarms + snapshot.approvals + snapshot.answers
}

/// What the owner can act on now: the count on the menu bar item and the Dock icon.
public func waitingCount(_ snapshot: InboxSnapshot) -> Int {
    snapshot.approvals.count + snapshot.answers.count
}

/// Approvals and questions that wait for the owner in one repository.
public func waitingCount(_ snapshot: InboxSnapshot, repo: String) -> Int {
    (snapshot.approvals + snapshot.answers).filter { $0.repo == repo }.count
}

/// Where a click on an inbox notification takes the owner.
public enum InboxRoute: Equatable, Sendable {
    /// The Review window of a PR that waits for approval.
    case review(url: String, title: String)
    /// The Review window of a kit update.
    case update
    /// The agent's question, on GitHub.
    case browser(url: String)
    /// The Projects window, where the alarm and its repository are shown.
    case projects
}

public func inboxRoute(for item: InboxItem) -> InboxRoute {
    switch item.kind {
    case .approve: .review(url: item.url, title: item.title)
    case .answer: .browser(url: item.url)
    // The CLI marks the "kit install is behind its origin main" alarm with the title "update".
    case .alarm where item.repo.isEmpty && item.title == "update": .update
    default: .projects
    }
}

public struct NotificationText: Equatable, Sendable {
    public let title: String
    public let body: String
}

public func notificationText(for item: InboxItem) -> NotificationText {
    let place = item.repo.isEmpty ? "Kit install" : item.repo
    switch item.kind {
    case .approve: return NotificationText(title: "Waiting for your approval", body: displaySafe("\(place): \(item.title)"))
    case .answer: return NotificationText(title: "The agent asks", body: displaySafe("\(place): \(item.title)"))
    case .alarm where item.repo.isEmpty && item.title == "update":
        return NotificationText(title: "A kit update is available", body: "Approvals wait until you update.")
    default: return NotificationText(title: "Guardrails alarm", body: displaySafe("\(place): \(item.note)"))
    }
}
