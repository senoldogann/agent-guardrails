import AppKit
import GuardrailsCore
import SwiftUI

/// Whether the owner has closed the welcome checklist once; until then it opens at launch.
enum Onboarding {
    static let completedKey = "onboardingCompleted"
}

/// The welcome checklist: what this Mac needs before Guardrails is useful, each step with its live state and
/// the one action that does it. Opens at the first launch; Settings opens it again.
struct OnboardingView: View {
    let model: AppModel
    let close: () -> Void
    @AppStorage(Onboarding.completedKey) private var completed = false
    @State private var githubSignedIn: Bool?
    @State private var githubProblem: String?

    var body: some View {
        let steps = onboardingSteps(facts)
        VStack(alignment: .leading, spacing: 22) {
            OnboardingHeader()
            VStack(spacing: 8) {
                ForEach(steps) { step in
                    OnboardingRow(step: step, text: text(for: step.id, state: step.state)) {
                        action(for: step.id)
                    }
                }
            }
            HStack {
                Text(progress(steps)).font(.caption).foregroundStyle(Palette.textSecondary)
                Spacer()
                Button(onboardingIsComplete(steps) ? "Done" : "Finish later") {
                    completed = true
                    close()
                }
                .primaryAction()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 24)
        // Closing the tab counts like "Finish later": it opens again only from Settings.
        .onDisappear { completed = true }
        .task { await check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings, Terminal or the browser: the step may be done now.
            Task { await check() }
        }
    }

    private var facts: OnboardingFacts {
        OnboardingFacts(
            kitFound: model.setupProblem == nil,
            githubSignedIn: githubSignedIn,
            notificationsShown: model.notificationsShown,
            agentRegistered: model.projects?.agent?.registered,
            enforcedRepos: model.lastUpdated == nil ? nil : model.snapshot.repos.count)
    }

    private func check() async {
        do {
            githubSignedIn = try await githubIsSignedIn()
            githubProblem = nil
        } catch {
            githubSignedIn = false
            githubProblem = "Could not run gh: \(error)"
        }
        await model.recheckNotifications()
        if model.lastUpdated == nil { await model.refresh() }
        if model.projects?.agent == nil { await model.projects?.loadProjects() }
    }

    private func progress(_ steps: [OnboardingStep]) -> String {
        let required = steps.filter { !$0.isOptional }
        let done = required.filter { $0.state == .done }.count
        return "\(done) of \(required.count) required steps done"
    }

    private func text(for id: OnboardingStep.ID, state: OnboardingStep.State) -> OnboardingText {
        switch id {
        case .kit:
            OnboardingText(
                title: "The kit is installed",
                detail: model.setupProblem ?? "The app runs the guardrails command of your kit install.",
                actionTitle: nil)
        case .github:
            OnboardingText(
                title: "GitHub CLI is signed in",
                detail: githubProblem
                    ?? (state == .done
                        ? "Guardrails reads your repositories and pull requests with gh."
                        : "Run gh auth login in Terminal, then come back."),
                actionTitle: state == .todo ? "Check again" : nil)
        case .notifications:
            OnboardingText(
                title: "Notifications are allowed",
                detail: "So approvals, alarms and the agent's questions reach you while the menu is closed.",
                actionTitle: state == .todo ? "Allow…" : nil)
        case .agentApp:
            OnboardingText(
                title: "The agent has its own GitHub App",
                detail: "The agent pushes as its App, and you approve its PRs with GitHub reviews, also on your phone.",
                actionTitle: state == .todo ? "Create…" : nil)
        case .firstRepo:
            OnboardingText(
                title: "A repository has guardrails on",
                detail: "Open Projects, choose a repository and Set up: Claude opens a bootstrap PR you turn on.",
                actionTitle: state == .todo ? "Open Projects" : nil)
        }
    }

    private func action(for id: OnboardingStep.ID) {
        switch id {
        case .kit:
            return
        case .github:
            Task { await check() }
        case .notifications:
            Task { await model.allowNotifications() }
        case .agentApp:
            model.openReview(ActionRequest(kind: .agentCreate, target: "", label: "the agent App"))
        case .firstRepo:
            model.workspace.show(.overview)
        }
    }
}

struct OnboardingText {
    let title: String
    let detail: String
    /// nil when the step needs no button (done, or nothing the app can do).
    let actionTitle: String?
}

struct OnboardingHeader: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Guardrails").font(.displayTitle)
                Text("Agents work within the specs you lock, and nothing merges until you approve the exact commit. A few steps make this Mac ready.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OnboardingRow: View {
    let step: OnboardingStep
    let text: OnboardingText
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            OnboardingSymbol(state: step.state, isOptional: step.isOptional)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(text.title).font(.system(size: 13, weight: .medium))
                    if step.isOptional { Chip(text: "Recommended") }
                }
                Text(text.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle = text.actionTitle {
                Button(actionTitle, action: action).secondaryAction()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.hairline))
    }
}

struct OnboardingSymbol: View {
    let state: OnboardingStep.State
    let isOptional: Bool

    var body: some View {
        Group {
            switch state {
            case .done: OcticonImage(icon: .checkCircle, size: 14).foregroundStyle(Palette.textSecondary)
            case .todo:
                OcticonImage(icon: .circle, size: 14).foregroundStyle(isOptional ? Palette.textSecondary : Palette.textSecondary)
            case .checking: ProgressView().controlSize(.small)
            }
        }
        .font(.system(size: 18))
        .frame(width: 22)
    }
}
