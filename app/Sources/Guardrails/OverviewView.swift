import GuardrailsCore
import SwiftUI

/// The Projects window before a repository is chosen: what waits for the owner (the menu bar inbox) and
/// the enforced repositories, each one click from its page.
struct OverviewView: View {
    let model: AppModel
    let projects: ProjectsModel
    let select: (String) -> Void

    var body: some View {
        let groups = groupProjects(projects.projects, matching: "")
        let enforced = groups.needsYou + groups.on
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Overview").font(.displayTitle)
                    Text(summary(enforced: enforced.count))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textSecondary)
                }
                if let error = projects.lastError, !projects.projects.isEmpty {
                    StatusPanel(symbol: .alert, title: "Repositories could not be refreshed", message: error)
                }
                VStack(alignment: .leading, spacing: 12) {
                    InboxList(model: model, open: open)
                }
                if !enforced.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Enforced repositories")
                        RowGroup {
                            ForEach(Array(enforced.enumerated()), id: \.element.id) { index, project in
                                if index > 0 { Divider().padding(.leading, 40) }
                                EnforcedRepoRow(project: project, waiting: waitingCount(model.snapshot, repo: project.repo)) {
                                    select(project.repo)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Recent activity")
                    ActivityList(
                        entries: latestActivity(model.activity.entries, limit: 12),
                        emptyText: "Approvals, turning repos on or off, and what arrives in your inbox show up here.")
                }
            }
            .padding(Metrics.windowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    private func summary(enforced: Int) -> String {
        if projects.projects.isEmpty { return projects.isLoading ? "Loading repositories…" : "No repositories loaded" }
        let waiting = waitingCount(model.snapshot)
        let repos = enforced == 1 ? "1 enforced repository" : "\(enforced) enforced repositories"
        let waits = waiting == 0 ? "nothing waits for you" : (waiting == 1 ? "1 waits for you" : "\(waiting) wait for you")
        return "\(repos) · \(waits)"
    }

    private func open(_ request: ActionRequest) {
        model.openReview(request)
    }
}

/// An enforced repository on the overview: its state in words and a way to its page.
struct EnforcedRepoRow: View {
    let project: Project
    let waiting: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                RepoIcon(project: project, size: 16).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textPrimary)
                    Text(attentionLine(for: project, waiting: waiting) ?? modeText)
                        .font(.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if project.openPRs > 0 {
                    HStack(spacing: 4) {
                        OcticonImage(icon: .pullRequest, size: 11)
                        Text("\(project.openPRs)").font(.system(size: 11).monospacedDigit())
                    }
                    .foregroundStyle(Palette.textSecondary)
                }
                OcticonImage(icon: .chevronRight, size: 12).foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(project.repo)")
    }

    private var modeText: String {
        switch project.mode {
        case .review: "Review mode · approvals are GitHub reviews"
        case .status: "Status mode · approvals are your commit status"
        case nil: "Guardrails are on"
        }
    }
}
