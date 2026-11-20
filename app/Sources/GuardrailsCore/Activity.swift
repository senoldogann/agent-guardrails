import Foundation

/// How an activity ended, or that something new arrived in the inbox.
public enum ActivityOutcome: String, Codable, Sendable {
    /// The owner confirmed an action and it finished.
    case succeeded
    /// The action stopped with an error, before or after a confirmation.
    case failed
    /// The inbox showed something new: an approval, an alarm, a question or a PR to turn on.
    case arrived
}

/// One line of the activity log: what the owner did in the app and what arrived for them. Kept on this Mac
/// only; GitHub stays the record of what was merged and approved.
public struct ActivityEntry: Codable, Sendable, Hashable, Identifiable {
    public let date: Date
    public let outcome: ActivityOutcome
    /// "Approved", "Turned on", "Needs your approval", …
    public let summary: String
    /// owner/repo; empty for the kit install.
    public let repo: String
    /// The PR title or the action's label.
    public let title: String
    /// A commit, a note or the error's last line.
    public let detail: String
    /// The PR or repository link; empty when there is none.
    public let url: String

    public init(
        date: Date, outcome: ActivityOutcome, summary: String, repo: String, title: String, detail: String, url: String
    ) {
        self.date = date
        self.outcome = outcome
        self.summary = summary
        self.repo = repo
        self.title = title
        self.detail = detail
        self.url = url
    }

    public var id: String { [String(date.timeIntervalSince1970), outcome.rawValue, summary, repo, url].joined(separator: "|") }
}

private func activityEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

/// One JSON line, without its newline.
public func activityLine(_ entry: ActivityEntry) throws -> String {
    String(decoding: try activityEncoder().encode(entry), as: UTF8.self)
}

/// The activity file as read: its entries, oldest first, and the lines that are not entries (a line cut short
/// when the app was killed mid-write). One bad line must not hide the rest of the history.
public struct ActivityFile: Sendable, Equatable {
    public let entries: [ActivityEntry]
    public let unreadable: [JSONLinesError]
}

extension JSONLinesError: Equatable {
    public static func == (lhs: JSONLinesError, rhs: JSONLinesError) -> Bool {
        (lhs.source, lhs.lineNumber, lhs.line, lhs.reason) == (rhs.source, rhs.lineNumber, rhs.line, rhs.reason)
    }
}

public func parseActivity(_ text: String) -> ActivityFile {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var entries: [ActivityEntry] = []
    var unreadable: [JSONLinesError] = []
    for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
        do {
            entries.append(try decoder.decode(ActivityEntry.self, from: Data(line.utf8)))
        } catch {
            unreadable.append(
                JSONLinesError(source: "activity log", lineNumber: index + 1, line: String(line), reason: String(describing: error)))
        }
    }
    return ActivityFile(entries: entries, unreadable: unreadable)
}

/// The newest entries first.
public func latestActivity(_ entries: [ActivityEntry], limit: Int) -> [ActivityEntry] {
    Array(entries.sorted { $0.date > $1.date }.prefix(limit))
}

/// The newest entries of one repository first.
public func activity(of repo: String, in entries: [ActivityEntry], limit: Int) -> [ActivityEntry] {
    latestActivity(entries.filter { sameRepository($0.repo, repo) }, limit: limit)
}

/// The newest `keeping` entries, oldest first, for rewriting a log that grew past its limit.
public func trimActivity(_ entries: [ActivityEntry], keeping: Int) -> [ActivityEntry] {
    Array(entries.sorted { $0.date < $1.date }.suffix(keeping))
}

/// Log entries for what newly arrived in the inbox.
public func arrivalEntries(_ items: [InboxItem], at date: Date) -> [ActivityEntry] {
    items.map { item in
        let text = notificationText(for: item)
        return ActivityEntry(
            // A kit install alarm's title is a code for the app ("update"), not words for the owner.
            date: date, outcome: .arrived, summary: text.title, repo: item.repo, title: item.repo.isEmpty ? "" : item.title,
            detail: item.note, url: item.url)
    }
}
