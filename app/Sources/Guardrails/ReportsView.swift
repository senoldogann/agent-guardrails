import Foundation
import GuardrailsCore
import Observation
import SwiftUI

/// The Reports page's data: `guardrails report --days N --json` per window, kept for a while because a report
/// reads every merged PR and ruleset version of the window from GitHub.
@MainActor
@Observable
final class ReportsModel {
    struct Loaded: Equatable {
        let reports: [RepoReport]
        let loaded: Date
    }

    /// The window the page shows; it stays when the page is left and opened again.
    var window = ReportWindow.month
    private(set) var loaded: [ReportWindow: Loaded] = [:]
    private(set) var errors: [ReportWindow: String] = [:]
    private(set) var loading: Set<ReportWindow> = []
    private let configuration: AppConfiguration

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    /// Loads a window's reports unless a load younger than ten minutes is at hand.
    func load(_ window: ReportWindow) async {
        if let cached = loaded[window], Date().timeIntervalSince(cached.loaded) < 600 { return }
        await reload(window)
    }

    /// Loads a window's reports from GitHub now.
    func reload(_ window: ReportWindow) async {
        guard !loading.contains(window) else { return }
        loading.insert(window)
        defer { loading.remove(window) }
        do {
            let result = try await runCommand(
                command: ["/bin/bash", configuration.cliPath, "report", "--days", String(window.rawValue), "--json"],
                environment: cliEnvironment(inherited: ProcessInfo.processInfo.environment, eventsDescriptor: nil))
            guard result.status == 0 else {
                errors[window] = describeCommandFailure(result, command: "guardrails report")
                return
            }
            loaded[window] = Loaded(reports: try parseReports(result.standardOutput), loaded: Date())
            errors[window] = nil
        } catch {
            errors[window] = String(describing: error)
        }
    }
}

/// How agent work went in each enforced repository over 7, 30 or 90 days: merges, approval times, failed runs,
/// merges without an approval, and every ruleset change as an audit list. Read-only.
struct ReportsView: View {
    @Bindable var reports: ReportsModel

    var body: some View {
        let window = reports.window
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reports").font(.displayTitle)
                        Text(subtitle(window))
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Picker("Window", selection: $reports.window) {
                        ForEach(ReportWindow.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if let error = reports.errors[window] {
                    StatusPanel(symbol: .alert, title: "The report could not be loaded", message: error)
                }
                if let loaded = reports.loaded[window] {
                    if loaded.reports.isEmpty {
                        Text("No enforced repositories yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if !loaded.reports.isEmpty {
                        ReportTiles(reports: loaded.reports)
                    }
                    ForEach(loaded.reports) { RepoReportSection(report: $0) }
                } else if reports.loading.contains(window) {
                    ProgressView("Reading \(window.title) from GitHub…").controlSize(.small)
                }
            }
            .padding(Metrics.windowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Reports")
        .task(id: window) { await reports.load(window) }
    }

    private func subtitle(_ window: ReportWindow) -> String {
        guard let loaded = reports.loaded[window] else {
            return "How agent work went in your enforced repositories, from GitHub"
        }
        let time = loaded.loaded.formatted(date: .omitted, time: .shortened)
        return "How agent work went in your enforced repositories over the last \(window.title) · read at \(time)"
    }
}

/// One repository's numbers in plain words, then its ruleset changes.
struct RepoReportSection: View {
    let report: RepoReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: report.repo)
            RowGroup {
                ReportRow(icon: .gitMerge, title: "Pull requests", text: mergedSentence(report))
                Divider().padding(.leading, 40)
                ReportRow(
                    icon: .clock, title: "Time to approve",
                    text: durationSentence(report.approve, none: "No approved pull request merged"))
                Divider().padding(.leading, 40)
                ReportRow(
                    icon: .hourglass, title: "Time to merge",
                    text: durationSentence(report.merge, none: "No pull request merged"))
                Divider().padding(.leading, 40)
                ReportRow(icon: .sync, title: "Re-approvals", text: reapprovalSentence(report))
                Divider().padding(.leading, 40)
                ReportRow(icon: .checkCircle, title: "Guard and checks", text: checksSentence(report))
                Divider().padding(.leading, 40)
                ReportRow(icon: .shieldLock, title: "Admin merges", text: adminMergeSentence(report))
                ForEach(report.adminMerges) { merge in
                    Button {
                        openInBrowser(merge.url)
                    } label: {
                        OcticonLabel(
                            "#\(merge.number) \(displaySafe(merge.title)) · merged by \(merge.mergedBy) \(dateText(merge.mergedAt))",
                            icon: .linkExternal
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 40)
                    .padding(.trailing, 12)
                    .padding(.bottom, 8)
                }
            }
            if !report.partial.isEmpty {
                Text("\(report.partial.map { "#\($0)" }.joined(separator: ", ")) have more commits or events than the report reads; their numbers may be short.")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            RulesetAudit(changes: report.rulesetChanges)
        }
    }
}

struct ReportRow: View {
    let icon: Octicon
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OcticonImage(icon: icon, size: 16)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textPrimary)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// The ruleset changes of the window, newest first: when, who, and what changed.
struct RulesetAudit: View {
    let changes: [RulesetChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Ruleset changes")
                .padding(.top, 4)
            if changes.isEmpty {
                Text("No ruleset changed in this window.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            } else {
                RowGroup {
                    ForEach(Array(changes.enumerated()), id: \.offset) { index, change in
                        if index > 0 { Divider().padding(.leading, 12) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(dateText(change.time)) · \(change.actor) · \(change.ruleset)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.textPrimary)
                            ForEach(Array(change.changes.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }
}

/// A GitHub timestamp in the owner's time zone, or the text itself when it is not one.
private func dateText(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    return date.formatted(date: .abbreviated, time: .shortened)
}

/// The window's numbers across every enforced repository, before the per-repository detail: the counts that can
/// be added up, and the one number that matters most in red when it is not zero.
struct ReportTiles: View {
    let reports: [RepoReport]

    var body: some View {
        let merged = reports.reduce(0) { $0 + $1.merged.total }
        let byAgent = reports.reduce(0) { $0 + $1.merged.agent }
        let failed = reports.reduce(0) { $0 + $1.failed }
        let guardFailed = reports.reduce(0) { $0 + $1.guardFailed }
        let checksFailed = reports.reduce(0) { $0 + $1.checksFailed }
        let reapproved = reports.reduce(0) { $0 + $1.reapproved }
        let withoutApproval = reports.reduce(0) { $0 + $1.adminMerges.count }
        HStack(alignment: .top, spacing: 10) {
            StatTile(
                title: "Merges",
                value: "\(merged)",
                note: byAgent == 1 ? "1 by the agent" : "\(byAgent) by the agent"
            )
            StatTile(
                title: "Failed runs",
                value: "\(failed)",
                note: "\(guardFailed) guard · \(checksFailed) checks",
                tone: failed > 0 ? .warning : .plain
            )
            StatTile(
                title: "Re-approvals",
                value: "\(reapproved)",
                note: "a push drops the approval"
            )
            StatTile(
                title: "Without an approval",
                value: "\(withoutApproval)",
                note: withoutApproval > 0 ? "on the merged commit" : "none",
                tone: withoutApproval > 0 ? .danger : .plain
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Totals for every enforced repository")
    }
}

/// One number with its label and the line that says what it counts.
struct StatTile: View {
    enum Tone { case plain, warning, danger }

    let title: String
    let value: String
    var note: String = ""
    var tone: Tone = .plain

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tone == .danger ? Palette.danger : Palette.textPrimary)
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(tone == .danger ? Palette.danger : Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value). \(note)")
    }
}
