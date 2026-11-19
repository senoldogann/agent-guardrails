import GuardrailsCore
import SwiftUI

/// The main window's sidebar: the overview, every repository grouped by what it needs, and settings. A
/// click shows the page in the browse tab.
struct ProjectSidebar: View {
    let projects: ProjectsModel
    let snapshot: InboxSnapshot
    @Binding var selection: WorkspacePage?
    let search: String
    let createAgent: () -> Void
    /// Most of an owner's repositories are off; the group stays closed unless the owner opens it.
    @AppStorage("showsOffProjects") private var showsOff = false
    @AppStorage(AppStyle.key) private var style = AppStyle.glass

    var body: some View {
        let groups = groupProjects(projects.projects, matching: search)
        List(selection: $selection) {
            if search.isEmpty {
                OcticonLabel("Overview", icon: .apps)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .tag(WorkspacePage.overview)
            }
            ProjectSection(title: "Needs you", projects: groups.needsYou, snapshot: snapshot)
            ProjectSection(title: "On", projects: groups.on, snapshot: snapshot)
            ProjectSection(title: "Ready to turn on", projects: groups.ready, snapshot: snapshot)
            // A search shows its matches among the off repositories even while the group is closed.
            if !groups.off.isEmpty {
                Section(isExpanded: Binding(get: { showsOff || !search.isEmpty }, set: { showsOff = $0 })) {
                    ForEach(groups.off) { ProjectRow(project: $0, waiting: 0).tag(WorkspacePage.repository($0.repo)) }
                } header: {
                    Text("Off · \(groups.off.count)")
                }
            }
            if search.isEmpty {
                Section {
                    OcticonLabel("Settings", icon: .gear)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .tag(WorkspacePage.settings)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(style == .solid ? .hidden : .automatic)
        .background(style == .solid ? Palette.sidebar : .clear)
        .overlay {
            SidebarOverlay(isLoading: projects.isLoading, isEmpty: projects.projects.isEmpty, error: projects.lastError)
        }
        .safeAreaBar(edge: .bottom) {
            if let agent = projects.agent {
                AgentPanel(agent: agent, create: createAgent)
            }
        }
    }
}

/// Who the agent is on GitHub: its own App (review mode possible) or the owner's login.
struct AgentPanel: View {
    let agent: AgentInfo
    let create: () -> Void

    var body: some View {
        let detail = agent.registered ? (agent.slug ?? "") : "The agent uses your GitHub login"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                OcticonImage(icon: .person, size: 14)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary)
                Text(agent.registered ? "Agent App" : "Agent identity").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                AgentPanelAction(agent: agent, create: create)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(detail)
        }
        .padding(12)
        .floatingPanel(cornerRadius: Metrics.cardRadius)
        .padding(10)
    }
}

struct AgentPanelAction: View {
    let agent: AgentInfo
    let create: () -> Void

    var body: some View {
        if agent.registered, let installURL = agent.installURL {
            Button("Manage") { openInBrowser(installURL) }
                .secondaryAction()
                .fixedSize()
                .help("Choose which repositories the agent App may work in")
        } else if !agent.registered {
            Button("Create…", action: create)
                .primaryAction()
                .fixedSize()
                .help("Register the agent's own GitHub App, so you can approve its PRs with GitHub reviews")
        }
    }
}

struct ProjectSection: View {
    let title: String
    let projects: [Project]
    let snapshot: InboxSnapshot

    var body: some View {
        if !projects.isEmpty {
            Section(title) {
                ForEach(projects) { project in
                    ProjectRow(project: project, waiting: waitingCount(snapshot, repo: project.repo))
                        .tag(WorkspacePage.repository(project.repo))
                }
            }
        }
    }
}

struct SidebarOverlay: View {
    let isLoading: Bool
    let isEmpty: Bool
    let error: String?

    var body: some View {
        if isEmpty {
            if isLoading {
                ProgressView("Loading repositories…").controlSize(.small)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(Palette.textSecondary).padding()
            } else {
                Text("No repositories").font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

/// A repository in the sidebar: its name, then why it needs the owner, or its visibility and last push.
struct ProjectRow: View {
    let project: Project
    let waiting: Int

    var body: some View {
        let attention = attentionLine(for: project, waiting: waiting)
        HStack(spacing: 10) {
            RepoIcon(project: project, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(attention ?? projectSubtitle(project, now: Date()))
                    .font(.system(size: 11, weight: attention == nil ? .regular : .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if project.openPRs > 0 {
                HStack(spacing: 4) {
                    OcticonImage(icon: .pullRequest, size: 11)
                    Text("\(project.openPRs)").font(.system(size: 11).monospacedDigit())
                }
                .foregroundStyle(Palette.textSecondary)
                .help("\(project.openPRs) open pull requests")
            }
        }
        .padding(.vertical, 3)
        .help(attention ?? project.repo)
    }
}

/// GitHub's own repository icon (repository, private, fork) on a tile tinted by the guardrails state: green
/// when on, red on an alarm, amber when ready to turn on, neutral when off.
struct RepoIcon: View {
    let project: Project
    let size: CGFloat

    var body: some View {
        OcticonImage(icon: glyph, size: size)
            .foregroundStyle(project.state == .alarm ? Palette.danger : Palette.textSecondary)
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
    }

    private var glyph: Octicon {
        switch project.kind {
        case .fork: .repoForked
        case .privateRepo: .lock
        case .publicRepo: .repo
        }
    }

    private var accessibilityText: String {
        let kind = switch project.kind {
        case .fork: "Fork"
        case .privateRepo: "Private repository"
        case .publicRepo: "Public repository"
        }
        return "\(kind), guardrails \(stateWord(project.state))"
    }
}

/// "on", "off", …: the state in a sentence.
func stateWord(_ state: ProjectState) -> String {
    switch state {
    case .on: "on"
    case .alarm: "alarmed"
    case .ready: "ready to turn on"
    case .off: "off"
    case .noAdmin: "not possible without admin rights"
    }
}

/// "Private · 2 hr. ago": visibility and fork only when they say something, then the last push.
func projectSubtitle(_ project: Project, now: Date) -> String {
    let flags = [project.private ? "Private" : nil, project.fork ? "Fork" : nil].compactMap { $0 }
    return (flags + [shortRelativeTime(project.pushed, now: now)]).joined(separator: " · ")
}

struct StateDot: View {
    let state: ProjectState

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private var color: Color {
        switch state {
        case .on: Palette.textSecondary
        case .alarm: Palette.danger
        case .ready: Palette.textSecondary
        case .off, .noAdmin: Palette.hairline
        }
    }
}
