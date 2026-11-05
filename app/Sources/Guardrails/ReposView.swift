import GuardrailsCore
import SwiftUI

/// The main window: enforced repositories with their ruleset state, turning a repo off, and repos to turn on.
struct ReposView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repositories").font(.system(size: 28, weight: .medium)).tracking(-0.5)
                        Text("Where agents work only within locked specs and every merge waits for you.")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .disabled(model.loadState == .loading)
                }
                if let problem = model.setupProblem {
                    StatusPanel(symbol: "wrench.and.screwdriver", title: "Setup needed", message: problem)
                }
                if let error = model.lastError {
                    StatusPanel(symbol: "wifi.exclamationmark", title: "Could not refresh", message: error)
                }
                ForEach(model.snapshot.alarms) { alarm in
                    VStack(alignment: .leading, spacing: 8) {
                        AlarmBanner(text: alarm.note)
                        if !alarm.repo.isEmpty {
                            Button("Restore guardrails on \(alarm.repo)") {
                                open(ActionRequest(kind: .turnOnRepo, target: alarm.repo, label: alarm.repo))
                            }
                            .buttonStyle(SecondaryPillStyle())
                            .disabled(model.snapshot.hasKitInstallAlarm)
                        }
                    }
                }
                enforced
                if !model.snapshot.turnOns.isEmpty { notYetEnforced }
            }
            .padding(Metrics.windowPadding)
        }
        .background(Palette.canvas)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { bringWindowsForward() }
    }

    private var enforced: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Enforced")
            if model.snapshot.repos.isEmpty {
                Card {
                    Text("No enforced repositories yet. In a project, ask your agent for /guardrails-init; its PR shows up below as a repository to turn on.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            ForEach(model.snapshot.repos) { repo in
                Card {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(repo.isActive ? Palette.success : Palette.danger)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.name).font(.system(size: 14, weight: .medium))
                            Text(repo.isActive ? "On · ruleset active" : "Ruleset \(repo.rulesetState)")
                                .font(.caption)
                                .foregroundStyle(repo.isActive ? Palette.textSecondary : Palette.danger)
                        }
                        Spacer()
                        Button("GitHub") { openInBrowser("https://github.com/\(repo.name)") }
                            .buttonStyle(SecondaryPillStyle())
                        Button("Turn off") {
                            open(ActionRequest(kind: .turnOff, target: repo.name, label: repo.name))
                        }
                        .buttonStyle(DestructivePillStyle())
                        .disabled(model.snapshot.hasKitInstallAlarm)
                    }
                }
            }
        }
    }

    private var notYetEnforced: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Ready to turn on")
            ForEach(model.snapshot.turnOns) { item in
                Card {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.repo).font(.system(size: 14, weight: .medium))
                            Text(item.title).font(.caption).foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        Button("Turn on") { open(ActionRequest(kind: .turnOn, target: item.url, label: item.title)) }
                            .buttonStyle(PrimaryPillStyle())
                            .disabled(model.snapshot.hasKitInstallAlarm)
                    }
                }
            }
        }
    }

    private func open(_ request: ActionRequest) {
        openWindow(id: WindowID.review, value: request)
        activateApp()
    }
}
