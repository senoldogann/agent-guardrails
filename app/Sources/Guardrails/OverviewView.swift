import GuardrailsCore
import SwiftUI

/// The Projects window before a repository is chosen: what waits for the owner (the menu bar inbox) and
/// the enforced repositories, each one click from its page.
struct OverviewView: View {
    let model: AppModel
    let projects: ProjectsModel
    let select: (String) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let groups = groupProjects(projects.projects, matching: "")
        let enforced = groups.needsYou + groups.on
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Overview").font(.system(size: 28, weight: .medium)).tracking(-0.5)
                    Text(summary(enforced: enforced.count))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textSecondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    InboxList(model: model, open: open)
                }
                if !enforced.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Enforced repositories")
                        ForEach(enforced) { project in
                            EnforcedRepoRow(project: project, waiting: waitingCount(model.snapshot, repo: project.repo)) {
                                select(project.repo)
                            }
                        }
                    }
                }
            }
            .padding(Metrics.windowPadding)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.canvas)
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
        openWindow(id: WindowID.review, value: request)
        activateApp()
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
                ProjectMonogram(project: project)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textPrimary)
                    Text(attentionLine(for: project, waiting: waiting) ?? modeText)
                        .font(.caption)
                        .foregroundStyle(project.state == .alarm ? Palette.danger : Palette.textSecondary)
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
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textSecondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.hairline))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.rowRadius))
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
