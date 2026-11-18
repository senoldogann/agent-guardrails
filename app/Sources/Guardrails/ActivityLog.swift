import AppKit
import Foundation
import GuardrailsCore
import Observation
import SwiftUI

/// The activity log on disk: `~/Library/Application Support/Guardrails/activity.jsonl`, one entry per line.
/// It grows by appending; past `maxEntries` it is rewritten with the newest `keptEntries`.
@MainActor
@Observable
final class ActivityLog {
    private(set) var entries: [ActivityEntry] = []
    /// Why the log could not be read or written; the app keeps working without it.
    private(set) var problem: String?
    let fileURL: URL?

    init() {
        let url: URL
        do {
            let folder = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appending(path: "Guardrails", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appending(path: "activity.jsonl")
        } catch {
            fileURL = nil
            report("The activity log has no folder: \(error)")
            return
        }
        fileURL = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = parseActivity(try String(contentsOf: url, encoding: .utf8))
            entries = file.entries
            if let first = file.unreadable.first {
                report("\(file.unreadable.count) line(s) of the activity log could not be read and are left out; the first: \(first)")
            }
        } catch {
            report("The activity log could not be read: \(error)")
        }
    }

    private func report(_ message: String) {
        problem = message
        NSLog("Guardrails: %@", message)
    }

    func record(_ new: [ActivityEntry]) {
        guard !new.isEmpty else { return }
        entries += new
        guard let fileURL else { return }
        do {
            if entries.count > maxEntries {
                entries = trimActivity(entries, keeping: keptEntries)
                try write(entries, to: fileURL)
            } else {
                try append(new, to: fileURL)
            }
            problem = nil
        } catch {
            report("The activity log could not be written: \(error)")
        }
    }

    func showInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

private let maxEntries = 1000
private let keptEntries = 500

private func append(_ entries: [ActivityEntry], to url: URL) throws {
    let text = try entries.map(activityLine).map { $0 + "\n" }.joined()
    if !FileManager.default.fileExists(atPath: url.path) {
        try text.write(to: url, atomically: true, encoding: .utf8)
        return
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

private func write(_ entries: [ActivityEntry], to url: URL) throws {
    try entries.map(activityLine).map { $0 + "\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
}

/// The log entry of a finished action: what the owner confirmed and how it ended. Nothing is logged when
/// the owner closed the window before confirming.
@MainActor
func activityEntry(for action: ActionModel, at date: Date) -> ActivityEntry? {
    let request = action.request
    let pr = action.plan?.pullRequest
    let summary: String
    let outcome: ActivityOutcome
    let detail: String
    switch action.phase {
    case .succeeded:
        outcome = .succeeded
        summary = successSummary(request.kind, ownMerge: pr?.isOwnMerge == true)
        detail = pr.map { "at \($0.shortSHA)" } ?? ""
    case .failed(let message):
        outcome = .failed
        summary = "\(actionName(request.kind)) stopped"
        detail = message.split(whereSeparator: \.isNewline).last.map { String($0.prefix(240)) } ?? ""
    default:
        return nil
    }
    let repo = request.kind == .update || request.kind == .agentCreate ? "" : (pr?.repo ?? request.repo)
    return ActivityEntry(
        date: date, outcome: outcome, summary: summary, repo: repo, title: displaySafe(pr?.title ?? request.label),
        detail: detail, url: pr?.url ?? (request.target.hasPrefix("https://") ? request.target : ""))
}

private func successSummary(_ kind: ActionRequest.Kind, ownMerge: Bool) -> String {
    switch kind {
    case .approve: ownMerge ? "Merged" : "Approved"
    case .turnOn, .turnOnRepo: "Turned on"
    case .turnOff: "Turned off"
    case .update: "Updated the kit"
    case .agentCreate: "Registered the agent App"
    }
}

private func actionName(_ kind: ActionRequest.Kind) -> String {
    switch kind {
    case .approve: "Approval"
    case .turnOn, .turnOnRepo: "Turning on"
    case .turnOff: "Turning off"
    case .update: "Update"
    case .agentCreate: "Agent App registration"
    }
}

/// Recent activity, newest first.
struct ActivityList: View {
    let entries: [ActivityEntry]
    let emptyText: String

    var body: some View {
        RowGroup {
            if entries.isEmpty {
                Text(emptyText).font(.caption).foregroundStyle(Palette.textSecondary).padding(12)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, 40) }
                ActivityRow(entry: entry)
            }
        }
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ActivitySymbol(outcome: entry.outcome).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? entry.summary : "\(entry.summary) · \(entry.title)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if !entry.url.isEmpty {
                Button {
                    openInBrowser(entry.url)
                } label: {
                    OcticonImage(icon: .linkExternal, size: 14)
                }
                .buttonStyle(.borderless)
                .help("Open on GitHub")
                .accessibilityLabel("Open on GitHub")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var subtitle: String {
        let place = entry.repo.isEmpty ? "Kit install" : entry.repo
        let time = relativeTime(entry.date, now: Date())
        return [place, entry.detail, time].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ActivitySymbol: View {
    let outcome: ActivityOutcome

    var body: some View {
        Group {
            switch outcome {
            case .succeeded: OcticonImage(icon: .checkCircle, size: 14).foregroundStyle(Palette.textSecondary)
            case .failed: OcticonImage(icon: .xCircle, size: 14).foregroundStyle(Palette.danger)
            case .arrived: OcticonImage(icon: .inbox, size: 14).foregroundStyle(Palette.textSecondary)
            }
        }
        .font(.system(size: 14))
        .frame(width: 16)
    }
}
