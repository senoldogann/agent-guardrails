import GuardrailsCore
import SwiftUI

/// One repository: its state, the one action that fits it, and its open pull requests.
struct ProjectDetail: View {
    let project: Project
    let model: AppModel
    let projects: ProjectsModel
    @Environment(\.openWindow) private var openWindow
    @State private var showsSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProjectHeader(
                    project: project, actionsLocked: model.snapshot.hasKitInstallAlarm, open: open,
                    startSetup: { showsSetup = true })
                if model.snapshot.hasKitInstallAlarm {
                    StatusPanel(
                        symbol: "lock", title: "Actions are locked",
                        message: "The kit install has an alarm (see the menu bar). On, off and approve refuse until it is fixed.")
                }
                ProjectStateCard(
                    project: project, setupStarted: projects.setupsStarted[project.repo], open: open,
                    startSetup: { showsSetup = true })
                if project.state == .on || project.state == .alarm {
                    PullRequestSection(
                        repo: project.repo, projects: projects, approvalsLocked: model.snapshot.hasKitInstallAlarm,
                        open: open)
                }
            }
            .padding(Metrics.windowPadding)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.canvas)
        .navigationTitle(project.name)
        .sheet(isPresented: $showsSetup) {
            SetupSheet(project: project) {
                projects.markSetupStarted(project.repo)
            }
        }
    }

    private func open(_ request: ActionRequest) {
        openWindow(id: WindowID.review, value: request)
        activateApp()
    }
}

struct ProjectHeader: View {
    let project: Project
    let actionsLocked: Bool
    let open: (ActionRequest) -> Void
    let startSetup: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(project.name).font(.system(size: 28, weight: .medium)).tracking(-0.5)
                HStack(spacing: 8) {
                    StateChip(state: project.state)
                    if project.private { Chip(text: "Private") }
                    if project.fork { Chip(text: "Fork") }
                    Text(project.repo).font(.caption).foregroundStyle(Palette.textSecondary)
                    Text("· pushed \(relativeTime(project.pushed))").font(.caption).foregroundStyle(Palette.textSecondary)
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
            .buttonStyle(.glass)
            switch project.state {
            case .ready:
                Button {
                    open(ActionRequest(kind: .turnOn, target: project.setupURL, label: project.repo))
                } label: {
                    Label("Turn on", systemImage: "power").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.textPrimary)
                .disabled(actionsLocked)
            case .off:
                Button(action: startSetup) {
                    Label("Set up…", systemImage: "terminal").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                    .tint(Palette.textPrimary)
            case .alarm:
                Button {
                    open(ActionRequest(kind: .turnOnRepo, target: project.repo, label: project.repo))
                } label: {
                    Label("Restore", systemImage: "arrow.counterclockwise").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.dangerFill)
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
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
            }
        }
    }
}

struct ProjectStateCard: View {
    let project: Project
    let setupStarted: Date?
    let open: (ActionRequest) -> Void
    let startSetup: () -> Void

    var body: some View {
        switch project.state {
        case .on:
            Card {
                Explainer(
                    symbol: "checkmark.shield.fill", color: Palette.success, title: "Guardrails are on",
                    text: "Agents work only within locked specs here, and every merge waits for the checks and your approval of the exact commit.")
            }
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
                        symbol: "shippingbox", color: Palette.warning, title: "Ready to turn on",
                        text: "The set-up PR is open. Turning on checks its kit files against your installed kit, merges exactly the commit you confirm and applies the ruleset.")
                    HStack {
                        Text(displaySafe(project.setupTitle)).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button {
                            openInBrowser(project.setupURL)
                        } label: {
                            GitHubLabel(title: "Open PR")
                        }
                        .buttonStyle(SecondaryPillStyle())
                    }
                }
            }
        case .off:
            OffCard(project: project, setupStarted: setupStarted, startSetup: startSetup)
        case .noAdmin:
            Card {
                Explainer(
                    symbol: "person.badge.key", color: Palette.textSecondary, title: "No admin rights",
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
                    symbol: "hourglass", color: Palette.warning, title: "Setting up…",
                    text: "Started \(setupStarted.formatted(date: .omitted, time: .shortened)) in Terminal. When Claude opens the set-up PR, this project moves to Ready to turn on. Refresh to check; if Terminal closed early, set it up again.")
            } else {
                Explainer(
                    symbol: "shield.slash", color: Palette.textSecondary, title: "Guardrails are off",
                    text: "Agents work here as they normally do. Set up adds the kit with Claude in Terminal: it opens a set-up PR, and you turn it on from here once you have looked at it.")
            }
        }
    }
}

struct Explainer: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(color).frame(width: 22)
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

/// English, like the rest of the app; the raw value when GitHub sends something that is not ISO 8601.
private func formatRelative(_ iso: String, style: RelativeDateTimeFormatter.UnitsStyle, now: Date) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.unitsStyle = style
    return formatter.localizedString(for: date, relativeTo: now)
}
