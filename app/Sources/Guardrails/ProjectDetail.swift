import GuardrailsCore
import SwiftUI

/// One repository: its state, the one action that fits it, and its open pull requests.
struct ProjectDetail: View {
    let project: Project
    let model: AppModel
    let projects: ProjectsModel
    @State private var showsSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProjectHeader(
                    project: project, actionsLocked: model.snapshot.hasKitInstallAlarm, open: open,
                    startSetup: { showsSetup = true })
                if model.snapshot.hasKitInstallAlarm {
                    StatusPanel(
                        symbol: .lock, title: "Actions are locked",
                        message: "The kit install needs attention: use Update in the menu bar, or fix the alarm shown there. On, off and approve refuse until then.")
                }
                ProjectStateCard(
                    project: project, setupStarted: projects.setupsStarted[project.repo], agent: projects.agent,
                    actionsLocked: model.snapshot.hasKitInstallAlarm, open: open, startSetup: { showsSetup = true })
                if project.state == .on || project.state == .alarm {
                    PullRequestSection(
                        repo: project.repo, projects: projects, approvalsLocked: model.snapshot.hasKitInstallAlarm,
                        open: open, openPullRequest: { model.workspace.showPullRequest($0) })
                }
                let history = activity(of: project.repo, in: model.activity.entries, limit: 8)
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Activity")
                        ActivityList(entries: history, emptyText: "")
                    }
                }
            }
            .padding(Metrics.windowPadding)
            .frame(maxWidth: pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(project.name)
        .sheet(isPresented: $showsSetup) {
            SetupSheet(project: project) {
                projects.markSetupStarted(project.repo)
            }
        }
    }

    private func open(_ request: ActionRequest) {
        model.openReview(request)
    }
}

struct ProjectHeader: View {
    let project: Project
    let actionsLocked: Bool
    let open: (ActionRequest) -> Void
    let startSetup: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RepoIcon(project: project, size: 46)
            VStack(alignment: .leading, spacing: 6) {
                Text(project.name).font(.system(size: 28, weight: .medium)).tracking(-0.5)
                HStack(spacing: 8) {
                    StateChip(state: project.state)
                    if project.private { Chip(text: "Private") }
                    if project.fork { Chip(text: "Fork") }
                    Text("\(project.repo) · pushed \(relativeTime(project.pushed))")
                        .font(.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            HeaderActions(project: project, actionsLocked: actionsLocked, open: open, startSetup: startSetup)
        }
    }
}

/// The one primary action of a state; turning off stays behind the overflow menu.
struct HeaderActions: View {
    let project: Project
    let actionsLocked: Bool
    let open: (ActionRequest) -> Void
    let startSetup: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                openInBrowser("https://github.com/\(project.repo)")
            } label: {
                GitHubLabel(title: "GitHub")
            }
            .secondaryAction()
            switch project.state {
            case .ready:
                Button {
                    open(ActionRequest(kind: .turnOn, target: project.setupURL, label: project.repo))
                } label: {
                    OcticonLabel("Turn on", icon: .plug).labelStyle(.titleAndIcon)
                }
                .primaryAction()
                .disabled(actionsLocked)
            case .off:
                Button(action: startSetup) {
                    OcticonLabel("Set up…", icon: .terminal).labelStyle(.titleAndIcon)
                }
                .primaryAction()
            case .alarm:
                Button {
                    open(ActionRequest(kind: .turnOnRepo, target: project.repo, label: project.repo))
                } label: {
                    OcticonLabel("Restore", icon: .history).labelStyle(.titleAndIcon)
                }
                .destructiveAction()
                .disabled(actionsLocked)
            case .on, .noAdmin:
                EmptyView()
            }
            if project.state == .on || project.state == .alarm {
                Menu {
                    Button("Turn off guardrails…", role: .destructive) {
                        open(ActionRequest(kind: .turnOff, target: project.repo, label: project.repo))
                    }
                    .disabled(actionsLocked)
                } label: {
                    OcticonImage(icon: .kebabHorizontal, size: 14)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .secondaryAction()
                .fixedSize()
            }
        }
    }
}

struct ProjectStateCard: View {
    let project: Project
    let setupStarted: Date?
    let agent: AgentInfo?
    let actionsLocked: Bool
    let open: (ActionRequest) -> Void
    let startSetup: () -> Void

    var body: some View {
        switch project.state {
        case .on:
            OnCard(project: project, agent: agent, actionsLocked: actionsLocked, open: open)
        case .alarm:
            VStack(alignment: .leading, spacing: 10) {
                AlarmBanner(text: "\(project.repo): \(project.note)")
                Text("Restore applies the ruleset again after checking the kit files on \(project.branch).")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        case .ready:
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Explainer(
                        symbol: .box, color: Palette.warning, title: "Ready to turn on",
                        text: "The bootstrap PR is open. Turning on checks its kit files against your installed kit, merges exactly the commit you confirm and applies the ruleset.")
                    HStack {
                        Text(displaySafe(project.setupTitle)).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button {
                            openInBrowser(project.setupURL)
                        } label: {
                            GitHubLabel(title: "Open PR")
                        }
                        .secondaryAction()
                    }
                }
            }
        case .off:
            OffCard(project: project, setupStarted: setupStarted, startSetup: startSetup)
        case .noAdmin:
            Card {
                Explainer(
                    symbol: .key, color: Palette.textSecondary, title: "No admin rights",
                    text: "You cannot apply rulesets in \(project.repo), so guardrails cannot be enforced here.")
            }
        }
    }
}

struct OffCard: View {
    let project: Project
    let setupStarted: Date?
    let startSetup: () -> Void

    var body: some View {
        Card {
            if let setupStarted {
                Explainer(
                    symbol: .hourglass, color: Palette.warning, title: "Setting up…",
                    text: "Started \(setupStarted.formatted(date: .omitted, time: .shortened)) in Terminal. When Claude opens the bootstrap PR, this project moves to Ready to turn on. Refresh to check; if Terminal closed early, set it up again.")
            } else {
                Explainer(
                    symbol: .shieldX, color: Palette.textSecondary, title: "Guardrails are off",
                    text: "Agents work here as they normally do. Set up adds the kit with Claude in Terminal: it opens a bootstrap PR, and you turn it on from here once you have looked at it.")
            }
        }
    }
}

struct Explainer: View {
    let symbol: Octicon
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OcticonImage(icon: symbol, size: 14).font(.system(size: 18)).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.surfaceMuted))
            .overlay(Capsule().strokeBorder(Palette.hairline))
    }
}

struct StateChip: View {
    let state: ProjectState

    var body: some View {
        HStack(spacing: 5) {
            StateDot(state: state)
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(Palette.surfaceMuted))
        .overlay(Capsule().strokeBorder(Palette.hairline))
    }

    private var label: String {
        switch state {
        case .on: "On"
        case .alarm: "Alarm"
        case .ready: "Ready to turn on"
        case .off: "Off"
        case .noAdmin: "No admin rights"
        }
    }
}

/// "3 hours ago" for an ISO 8601 time from GitHub.
func relativeTime(_ iso: String) -> String {
    formatRelative(iso, style: .full, now: Date())
}

/// "3 hr. ago", for tight spaces like the sidebar.
func shortRelativeTime(_ iso: String, now: Date) -> String {
    formatRelative(iso, style: .abbreviated, now: now)
}

/// "3 minutes ago" for a moment the app recorded.
func relativeTime(_ date: Date, now: Date) -> String {
    formatRelative(date, style: .full, now: now)
}

/// English, like the rest of the app; the raw value when GitHub sends something that is not ISO 8601.
private func formatRelative(_ iso: String, style: RelativeDateTimeFormatter.UnitsStyle, now: Date) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    return formatRelative(date, style: style, now: now)
}

private func formatRelative(_ date: Date, style: RelativeDateTimeFormatter.UnitsStyle, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.unitsStyle = style
    return formatter.localizedString(for: date, relativeTo: now)
}

/// An enforced repository: how approvals work here, and the step to review mode when it is one click away.
struct OnCard: View {
    let project: Project
    let agent: AgentInfo?
    let actionsLocked: Bool
    let open: (ActionRequest) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Explainer(symbol: .shieldCheck, color: Palette.success, title: title, text: text)
                if project.canSwitchToReviewMode {
                    HStack {
                        Text("The agent App is installed here.").font(.caption).foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Button("Switch to review mode") {
                            open(ActionRequest(kind: .turnOnRepo, target: project.repo, label: project.repo))
                        }
                        .primaryAction()
                        .disabled(actionsLocked)
                    }
                } else if project.mode == .status, project.agentApp == .missing, let installURL = agent?.installURL {
                    HStack {
                        Text("Add this repository to the agent App to approve its PRs with GitHub reviews.")
                            .font(.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button {
                            openInBrowser(installURL)
                        } label: {
                            GitHubLabel(title: "Add to agent App")
                        }
                        .secondaryAction()
                    }
                }
            }
        }
    }

    private var title: String {
        switch project.mode {
        case .review: "Guardrails are on · review mode"
        case .status: "Guardrails are on · status mode"
        case nil: "Guardrails are on"
        }
    }

    private var text: String {
        switch project.mode {
        case .review:
            "The agent pushes as its own GitHub App. Approve its PRs with Review here, on github.com or in GitHub Mobile; every new push needs a new approval. Review merges your own PRs."
        case .status, nil:
            "Agents work only within locked specs here, and every merge waits for the checks and your approval of the exact commit."
        }
    }
}
