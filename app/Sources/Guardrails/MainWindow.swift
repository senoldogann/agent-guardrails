import AppKit
import GuardrailsCore
import SwiftUI

/// The one window of the app, laid out like an editor: the sidebar on the left, tabs on top, the page below
/// them and a status bar at the bottom. It fills the screen well in full screen.
struct MainWindow: View {
    let model: AppModel
    let projects: ProjectsModel
    @State private var search = ""
    @State private var showsPalette = false
    @FocusState private var searchFocused: Bool
    @AppStorage(AppStyle.key) private var style = AppStyle.glass

    var body: some View {
        let workspace = model.workspace
        NavigationSplitView {
            ProjectSidebar(
                projects: projects, workspace: workspace, snapshot: model.snapshot, selection: sidebarSelection,
                search: search,
                settingsShown: workspace.strip.selected == .settings,
                openSettings: { workspace.show(.settings) }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            VStack(spacing: 0) {
                // A minimum of zero: a page taller than the window scrolls inside it instead of pushing the
                // status bar (and the sidebar with it) out of the window.
                WorkspacePageView(page: workspace.strip.selected, model: model, projects: projects)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                WorkspaceStatusBar(model: model, projects: projects)
            }
            .background { pageBackground.ignoresSafeArea() }
            .overlay {
                if showsPalette {
                    CommandPalette(model: model, projects: projects, isShown: $showsPalette)
                        .transition(.opacity)
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search repositories")
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await refreshAll() }
                } label: {
                    OcticonImage(icon: .sync, size: 14).accessibilityLabel("Refresh")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (⌘R)")
                .disabled(projects.isLoading)
            }
        }
        .background {
            WorkspaceShortcuts(
                workspace: workspace, focusSearch: { searchFocused = true },
                openPalette: { showsPalette = true })
        }
        .navigationTitle(pageTitle(workspace.strip.selected, workspace: workspace, projects: projects))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 900, minHeight: 600)
        // Glass: the desktop shows through, blurred, behind the pages. Solid: one near-black or near-white color.
        .containerBackground(windowBackground, for: .window)
        .onAppear { bringWindowsForward() }
        .task { await refreshWhileOpen() }
    }

    /// Behind the tabs, the page and the status bar: the glass veil, or nothing over the solid canvas.
    private var pageBackground: Color {
        switch style {
        case .glass: Palette.glassVeil
        case .solid: .clear
        }
    }

    private var windowBackground: AnyShapeStyle {
        switch style {
        case .glass: AnyShapeStyle(.thinMaterial)
        case .solid: AnyShapeStyle(Palette.canvas)
        }
    }

    /// The sidebar marks whatever page the window shows, browse or open, so the row of the page on screen is
    /// the one that reads as selected.
    private var sidebarSelection: Binding<WorkspacePage?> {
        Binding(
            get: { model.workspace.strip.selected },
            set: { page in
                if let page { model.workspace.show(page) }
            })
    }

    private func refreshAll() async {
        await model.refresh()
        await projects.loadProjects()
        // A report reads the whole window from GitHub, so it reloads only while its page is shown.
        if model.workspace.strip.selected == .reports {
            await projects.reports.reload(projects.reports.window)
        }
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

/// The main window reloads the repositories this often while it stays open; Refresh reloads at once.
private let projectsRefreshInterval = Duration.seconds(15 * 60)

/// Keyboard shortcuts on invisible buttons: ⌘W closes the open page (the window when a browse page is shown),
/// ⌃Tab and ⌃⇧Tab step through the open pages, ⌘F searches the repositories, ⌘K jumps anywhere.
struct WorkspaceShortcuts: View {
    let workspace: Workspace
    let focusSearch: () -> Void
    let openPalette: () -> Void

    var body: some View {
        ZStack {
            Button("Close Tab") {
                if !workspace.closeSelected() { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Next Tab") { workspace.step(by: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { workspace.step(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Search repositories", action: focusSearch)
                .keyboardShortcut("f", modifiers: .command)
            Button("Go to…", action: openPalette)
                .keyboardShortcut("k", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// The page the window shows.
struct WorkspacePageView: View {
    let page: WorkspacePage
    let model: AppModel
    let projects: ProjectsModel

    var body: some View {
        switch page {
        case .overview:
            OverviewView(model: model, projects: projects) { model.workspace.show(.repository($0)) }
        case .reports:
            ReportsView(reports: projects.reports)
        case .repository(let repo):
            if let project = projects.project(named: repo) {
                ProjectDetail(project: project, model: model, projects: projects).id(project.repo)
            } else {
                MissingPage(text: projects.isLoading ? "Loading \(repo)…" : "\(repo) is not among your repositories.")
            }
        case .settings:
            SettingsView(model: model)
        case .pullRequest(let ref):
            if let pullRequest = model.workspace.pullRequests[ref] {
                PullRequestPage(pullRequest: pullRequest, model: model).id(ref)
            }
        case .review(let run):
            if let session = model.workspace.reviews[run] {
                ReviewView(session: session) { model.workspace.close(page) }.id(run)
            }
        case .welcome:
            OnboardingView(model: model) { model.workspace.close(.welcome) }
        }
    }
}

struct MissingPage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The tabs, as in an editor: an icon and a title each, the selected one raised, a close button on the
/// others when the pointer is over them or they are selected. The browse tab cannot close.
struct WorkspaceStatusBar: View {
    let model: AppModel
    let projects: ProjectsModel

    var body: some View {
        let snapshot = model.snapshot
        let waiting = waitingCount(snapshot)
        HStack(spacing: 16) {
            OcticonLabel(updatedText, icon: .sync)
            if !snapshot.alarms.isEmpty {
                OcticonLabel(snapshot.alarms.count == 1 ? "1 alarm" : "\(snapshot.alarms.count) alarms", icon: .alert)
                    .foregroundStyle(Palette.danger)
            }
            OcticonLabel(waiting == 0 ? "Nothing waits for you" : (waiting == 1 ? "1 waits for you" : "\(waiting) wait for you"), icon: .inbox)
            OcticonLabel(enforcedText, icon: .shieldCheck)
            Spacer()
            if model.loadState == .loading || projects.isLoading {
                ProgressView().controlSize(.mini)
            }
            if model.notificationsShown == false {
                OcticonLabel("Notifications off", icon: .bellSlash)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11))
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var updatedText: String {
        guard let updated = model.lastUpdated else { return "Not loaded yet" }
        return "Updated \(updated.formatted(date: .omitted, time: .shortened))"
    }

    /// Counted as the overview counts them: enforced repositories, alarms included.
    private var enforcedText: String {
        let groups = groupProjects(projects.projects, matching: "")
        let count = groups.needsYou.count + groups.on.count
        return count == 1 ? "1 enforced repository" : "\(count) enforced repositories"
    }
}

/// A tab's title: the page's name, a PR's number and title once loaded, a review's action and target.
@MainActor
func pageTitle(_ page: WorkspacePage, workspace: Workspace, projects: ProjectsModel) -> String {
    switch page {
    case .overview: return "Overview"
    case .reports: return "Reports"
    case .repository(let repo): return projects.project(named: repo)?.name ?? repo
    case .settings: return "Settings"
    case .welcome: return "Welcome"
    case .pullRequest(let ref):
        if case .loaded(let pr) = workspace.pullRequests[ref]?.detail { return "#\(ref.number) \(displaySafe(pr.title))" }
        return "#\(ref.number)"
    case .review(let run):
        guard let request = workspace.reviews[run]?.request else { return "Review" }
        return "\(request.windowTitle) · \(displaySafe(request.label))"
    }
}

@MainActor
func pageSymbol(_ page: WorkspacePage, workspace: Workspace) -> Octicon {
    switch page {
    case .overview: .apps
    case .reports: .graph
    case .repository: .repo
    case .settings: .gear
    case .welcome: .info
    case .pullRequest: .pullRequest
    case .review(let run):
        switch workspace.reviews[run]?.action.phase {
        case .succeeded: .checkCircle
        case .failed: .xCircle
        case .cancelled: .skip
        default: .passkey
        }
    }
}
