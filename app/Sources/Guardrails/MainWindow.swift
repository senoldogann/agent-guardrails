import AppKit
import GuardrailsCore
import SwiftUI

/// The one window of the app, laid out like an editor: the sidebar on the left, tabs on top, the page below
/// them and a status bar at the bottom. It fills the screen well in full screen.
struct MainWindow: View {
    let model: AppModel
    let projects: ProjectsModel
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let workspace = model.workspace
        NavigationSplitView {
            ProjectSidebar(
                projects: projects, snapshot: model.snapshot, selection: sidebarSelection, search: search,
                createAgent: { model.openReview(ActionRequest(kind: .agentCreate, target: "", label: "the agent App")) }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            VStack(spacing: 0) {
                WorkspaceTabBar(model: model, projects: projects)
                // A minimum of zero: a page taller than the window scrolls inside it instead of pushing the
                // tab and status bars (and the sidebar with them) out of the window.
                WorkspacePageView(page: workspace.strip.selected, model: model, projects: projects)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                WorkspaceStatusBar(model: model, projects: projects)
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
        .background { WorkspaceShortcuts(workspace: workspace, focusSearch: { searchFocused = true }) }
        .navigationTitle(pageTitle(workspace.strip.selected, workspace: workspace, projects: projects))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 900, minHeight: 600)
        // The window itself is glass: the desktop shows through, blurred, behind the pages.
        .containerBackground(.thinMaterial, for: .window)
        .onAppear { bringWindowsForward() }
        .task { await refreshWhileOpen() }
    }

    /// The sidebar marks the browse tab's page while that tab is selected, and nothing while another tab is,
    /// so a click on any row (even the one the browse tab shows) brings the browse tab back.
    private var sidebarSelection: Binding<WorkspacePage?> {
        Binding(
            get: {
                let strip = model.workspace.strip
                return strip.selected.isBrowsePage ? strip.browse : nil
            },
            set: { page in
                if let page { model.workspace.show(page) }
            })
    }

    private func refreshAll() async {
        await model.refresh()
        await projects.loadProjects()
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

/// Keyboard shortcuts of the tabs, on invisible buttons: ⌘W closes the tab (the window when the browse tab
/// is selected), ⌃Tab and ⌃⇧Tab step through the tabs, ⌘F searches the repositories.
struct WorkspaceShortcuts: View {
    let workspace: Workspace
    let focusSearch: () -> Void

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
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// The page of the selected tab.
struct WorkspacePageView: View {
    let page: WorkspacePage
    let model: AppModel
    let projects: ProjectsModel

    var body: some View {
        switch page {
        case .overview:
            OverviewView(model: model, projects: projects) { model.workspace.show(.repository($0)) }
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
struct WorkspaceTabBar: View {
    let model: AppModel
    let projects: ProjectsModel

    var body: some View {
        let workspace = model.workspace
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(workspace.strip.tabs, id: \.self) { page in
                    WorkspaceTab(
                        title: pageTitle(page, workspace: workspace, projects: projects),
                        symbol: pageSymbol(page, workspace: workspace),
                        isSelected: workspace.strip.selected == page,
                        canClose: !page.isBrowsePage,
                        select: { workspace.select(page) },
                        close: { workspace.close(page) })
                }
            }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct WorkspaceTab: View {
    let title: String
    let symbol: Octicon
    let isSelected: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            OcticonImage(icon: symbol, size: 14)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if canClose {
                Button(action: close) {
                    OcticonImage(icon: .x, size: 14)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isSelected ? 1 : 0)
                .help("Close tab (⌘W)")
                .accessibilityLabel("Close \(title)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, canClose ? 7 : 12)
        .frame(height: 30)
        .frame(maxWidth: 240)
        // The selected tab is a piece of glass; the others are labels on the window until hovered.
        .glassEffect(isSelected ? .regular.interactive() : (isHovered ? .clear.interactive() : .identity), in: .capsule)
        .contentShape(Capsule())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", select)
    }
}

/// The window's last line: when the inbox was read, what waits, alarms, and whether anything loads.
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
