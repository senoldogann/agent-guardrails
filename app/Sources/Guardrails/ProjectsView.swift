import GuardrailsCore
import SwiftUI

/// The main window: every repository of the owner on the left, grouped by state; the selected one on the right.
struct ProjectsView: View {
    let model: AppModel
    let projects: ProjectsModel
    @State private var selection: String?
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(projects: projects, selection: $selection, search: search)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            ProjectDetailContainer(model: model, projects: projects, selection: selection)
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search repositories")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await projects.loadProjects() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(projects.isLoading)
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 820, minHeight: 540)
        .onAppear { bringWindowsForward() }
        .task { await refreshWhileOpen() }
    }

    /// Loads when the window opens and every 15 minutes while it stays open.
    private func refreshWhileOpen() async {
        while !Task.isCancelled {
            await projects.loadProjects()
            do {
                try await Task.sleep(for: projectsRefreshInterval)
            } catch {
                return
            }
        }
    }
}

/// The Projects window reloads this often while it stays open; the toolbar's Refresh reloads at once.
private let projectsRefreshInterval = Duration.seconds(15 * 60)

struct ProjectSidebar: View {
    let projects: ProjectsModel
    @Binding var selection: String?
    let search: String
    @State private var showsOff = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let groups = groupProjects(projects.projects, matching: search)
        List(selection: $selection) {
            ProjectSection(title: "Needs you", projects: groups.needsYou)
            ProjectSection(title: "On", projects: groups.on)
            ProjectSection(title: "Ready to turn on", projects: groups.ready)
            Section(isExpanded: $showsOff) {
                ForEach(groups.off) { ProjectRow(project: $0).tag($0.repo) }
            } header: {
                Text("Off · \(groups.off.count)")
            }
        }
        .listStyle(.sidebar)
        .overlay {
            SidebarOverlay(isLoading: projects.isLoading, isEmpty: projects.projects.isEmpty, error: projects.lastError)
        }
        .safeAreaInset(edge: .bottom) {
            if let agent = projects.agent {
                AgentPanel(agent: agent) {
                    openWindow(id: WindowID.review, value: ActionRequest(kind: .agentCreate, target: "", label: "the agent App"))
                    activateApp()
                }
            }
        }
    }
}

/// Who the agent is on GitHub: its own App (review mode possible) or the owner's login.
struct AgentPanel: View {
    let agent: AgentInfo
    let create: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.registered ? "person.badge.shield.checkmark" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 16))
                .foregroundStyle(Palette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.registered ? "Agent App" : "Agent identity").font(.system(size: 12, weight: .semibold))
                Text(agent.registered ? (agent.slug ?? "") : "The agent uses your GitHub login")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if agent.registered, let installURL = agent.installURL {
                Button("Manage") { openInBrowser(installURL) }
                    .buttonStyle(SecondaryPillStyle())
                    .fixedSize()
                    .help("Choose which repositories the agent App may work in")
            } else if !agent.registered {
                Button("Create…", action: create)
                    .buttonStyle(PrimaryPillStyle())
                    .fixedSize()
                    .help("Register the agent's own GitHub App, so you can approve its PRs with GitHub reviews")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surfaceMuted))
        .padding(10)
    }
}

struct ProjectSection: View {
    let title: String
    let projects: [Project]

    var body: some View {
        if !projects.isEmpty {
            Section(title) {
                ForEach(projects) { ProjectRow(project: $0).tag($0.repo) }
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

struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            ProjectMonogram(project: project)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(projectSubtitle(project, now: Date()))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if project.openPRs > 0 {
                HStack(spacing: 4) {
                    OcticonImage(icon: .pullRequest, size: 11)
                    Text("\(project.openPRs)").font(.system(size: 11).monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .help("\(project.openPRs) open pull requests")
            }
        }
        .padding(.vertical, 3)
    }
}

/// The repository's initial in a rounded square, with a colored badge when guardrails are on, ready or alarmed.
struct ProjectMonogram: View {
    let project: Project

    var body: some View {
        Text(project.name.prefix(1).uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.textSecondary)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surfaceMuted))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.hairline))
            .overlay(alignment: .bottomTrailing) {
                if project.state != .off {
                    StateDot(state: project.state)
                        .padding(2)
                        .background(Circle().fill(Palette.canvas))
                        .offset(x: 3, y: 3)
                }
            }
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
        case .on: Palette.success
        case .alarm: Palette.danger
        case .ready: Palette.warning
        case .off, .noAdmin: Palette.hairline
        }
    }
}

struct ProjectDetailContainer: View {
    let model: AppModel
    let projects: ProjectsModel
    let selection: String?

    var body: some View {
        if let selection, let project = projects.project(named: selection) {
            ProjectDetail(project: project, model: model, projects: projects).id(project.repo)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.shield").font(.system(size: 36, weight: .light))
                Text("Choose a repository").font(.system(size: 15, weight: .medium))
                Text("Turn guardrails on or off, set up new projects and review their pull requests.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Palette.textPrimary)
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
            .navigationTitle("Projects")
        }
    }
}
