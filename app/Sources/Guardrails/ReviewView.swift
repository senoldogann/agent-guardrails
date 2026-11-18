import GuardrailsCore
import SwiftUI

/// The review window of one action. Everything the owner reads comes from the CLI's plan event and sits on
/// opaque surfaces; only the bottom action bar is glass.
struct ReviewView: View {
    let request: ActionRequest
    let configuration: AppConfiguration
    let onFinish: @MainActor @Sendable (ActionModel) -> Void
    @State private var model: ActionModel?
    @State private var evidence = PullRequestEvidence()
    @State private var showsLog = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(request.windowTitle).font(.displayTitle).tracking(-0.3)
                    if let model {
                        planSection(model)
                        statusSection(model)
                        logSection(model)
                    }
                }
                .padding(Metrics.windowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let model { actionBar(model) }
        }
        .frame(minWidth: 540, minHeight: 560)
        .task {
            guard model == nil else { return }
            let started = ActionModel(request: request, configuration: configuration)
            model = started
            started.start(onFinish: onFinish)
        }
        .task(id: model?.plan?.pullRequest?.sha) {
            if let pr = model?.plan?.pullRequest { await evidence.load(pr) }
        }
        .onAppear { bringWindowsForward() }
        .onDisappear { model?.cancel() }
    }

    // MARK: plan

    @ViewBuilder
    private func planSection(_ model: ActionModel) -> some View {
        switch model.plan {
        case .none where request.kind == .agentCreate:
            if model.isRunning { AgentCreateCard() }
        case .none:
            Card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(displaySafe(request.label)) with guardrails…").font(.system(size: 13))
                }
            }
        case .update(let update):
            UpdatePlanCard(update: update)
        case .approve(let pr), .turnOn(let pr):
            pullRequestPlan(pr, model: model)
        case .turnOnRepo(let repoPlan):
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(repoPlan.repo).font(.system(size: 15, weight: .medium))
                    Text("The kit files on \(repoPlan.branch) match your installed kit. Turning on applies the ruleset: merges then wait for the checks and your approval.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        case .turnOff(let removal):
            removalPlan(removal)
        }
    }

    private func pullRequestPlan(_ pr: PullRequestPlan, model: ActionModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(pr.repo) · PR #\(pr.pr)").font(.caption).foregroundStyle(Palette.textSecondary)
                    Text(displaySafe(pr.title)).font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SHABadge(sha: pr.shortSHA)
                        Text("exactly this commit").font(.caption).foregroundStyle(Palette.textSecondary)
                        if case .loaded(let now) = evidence.snapshot, now.head.sha == pr.sha {
                            DiffStatsLabel(diff: .loaded(now.stats))
                        }
                        Spacer()
                        Button("Open changes on GitHub") {
                            if case .loaded(let now) = evidence.snapshot {
                                openInBrowser(now.compareURL(repo: pr.repo, sha: pr.sha))
                                model.markDiffOpened()
                            }
                        }
                        .secondaryAction()
                        .disabled(!evidence.snapshot.isLoaded)
                        .help("GitHub's diff of exactly \(pr.shortSHA), even if the PR moves on")
                    }
                    if case .failed(let message) = evidence.snapshot {
                        Text("Could not read the PR from GitHub, so the diff link waits: \(message). Load again with the button under Checks.")
                            .font(.caption)
                            .foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if case .loaded(let now) = evidence.snapshot, now.head.sha != pr.sha {
                        Label("The PR moved to \(now.head.sha.prefix(7)) after this check. Cancel, then review the new commit.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .turnOn = model.plan {
                        Label("Kit files match your installed kit", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.success)
                    }
                    if pr.isOwnMerge {
                        Label("Your own PR: GitHub does not take your review, so this merges it now. Your admin bypass skips the review, not the checks.", systemImage: "arrow.triangle.merge")
                            .font(.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ChecksCard(pr: pr, evidence: evidence)
            if let spec = evidence.spec { SpecCard(spec: spec) }
            FileGroups(files: pr.files)
        }
    }

    private func removalPlan(_ removal: RemovalPlan) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(removal.repo).font(.system(size: 15, weight: .medium))
                VStack(alignment: .leading, spacing: 4) {
                    Bullet("Deletes the agent-guardrails ruleset: merges no longer wait for checks or your approval.")
                    Bullet("Stops treating the repo as a kit repo on this Mac and removes its topic.")
                    Bullet("Keeps the repository settings the kit set (squash merge, read-only workflow token, pinned actions).")
                    if !removal.removed.isEmpty {
                        Bullet("Merges a PR on \(removal.branch) that removes \(removal.removed.count) kit files.")
                    }
                }
                ForEach(removal.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(Palette.warning)
                }
            }
        }
    }

    // MARK: status and log

    @ViewBuilder
    private func statusSection(_ model: ActionModel) -> some View {
        switch model.phase {
        case .awaitingConfirmation(let pending) where pending.step == .workflows:
            WorkflowWarning(files: model.plan?.pullRequest?.files.filter(\.isWorkflow) ?? [])
        case .working:
            Card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Working… do not close this window.").font(.system(size: 13))
                }
            }
        case .succeeded:
            ResultCard(
                symbol: "checkmark.circle.fill", color: Palette.success, title: successTitle(model),
                message: successMessage(model))
        case .failed(let message):
            ResultCard(symbol: "xmark.octagon.fill", color: Palette.danger, title: "Stopped", message: message)
        case .cancelled:
            ResultCard(symbol: "minus.circle", color: Palette.textSecondary, title: "Cancelled", message: "Nothing was changed.")
        case .preparing, .awaitingConfirmation, .verifyingOwner:
            if let problem = model.ownerCheckProblem {
                StatusPanel(symbol: "touchid", title: "Not confirmed", message: problem)
            }
        }
    }

    private func logSection(_ model: ActionModel) -> some View {
        DisclosureGroup("Details", isExpanded: $showsLog) {
            ScrollView {
                Text(model.log.isEmpty ? "No output yet." : model.log)
                    .font(.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surfaceMuted))
        }
        .font(.caption)
        .foregroundStyle(Palette.textSecondary)
    }

    private func successTitle(_ model: ActionModel) -> String {
        switch request.kind {
        case .approve: model.plan?.pullRequest?.isOwnMerge == true ? "Merged" : "Approved"
        case .turnOn, .turnOnRepo: "Guardrails are on"
        case .turnOff: "Guardrails are off"
        case .update: "Kit updated"
        case .agentCreate: "Agent App registered"
        }
    }

    private func successMessage(_ model: ActionModel) -> String {
        switch request.kind {
        case .approve where model.plan?.pullRequest?.isOwnMerge == true:
            "Your PR is merged at exactly the commit you confirmed."
        case .approve: "The PR merges by itself once its checks pass. A new push needs a new approval."
        case .turnOn, .turnOnRepo: "Ask your agent for /ticket-spec <ID> in this repository."
        case .turnOff: "Pull the default branch in your local clones so their .agent/ disappears too."
        case .update: "Guardrails restarts with the new version in a moment."
        case .agentCreate:
            "Install it with \"Only select repositories\" on your projects (Details has the link), then turn each one on again to switch it to review mode."
        }
    }

    // MARK: action bar

    private func actionBar(_ model: ActionModel) -> some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if model.isRunning {
                    Button("Cancel") {
                        model.cancel()
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.canCancel)
                } else {
                    Button("Close") { dismiss() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if model.needsDiffReview, !model.diffOpened, case .awaitingConfirmation(let pending) = model.phase,
                    pending.step == .commit
                {
                    Text("Open the changes first: human-owned, workflow or guardrail files change.")
                        .font(.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                confirmButton(model)
            }
            .padding(.horizontal, Metrics.windowPadding)
            .padding(.vertical, 14)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func confirmButton(_ model: ActionModel) -> some View {
        switch model.phase {
        case .awaitingConfirmation(let pending):
            Button {
                Task { await model.confirm() }
            } label: {
                Label(confirmTitle(pending, ownMerge: model.plan?.pullRequest?.isOwnMerge == true), systemImage: "touchid")
            }
            .buttonStyle(.glassProminent)
            .tint(request.kind == .turnOff ? Palette.dangerFill : Palette.accent)
            .disabled(pending.step == .commit && model.needsDiffReview && !model.diffOpened)
        case .verifyingOwner:
            ProgressView().controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func confirmTitle(_ pending: ConfirmRequest, ownMerge: Bool) -> String {
        switch (pending.step, request.kind) {
        case (.workflows, _): "I reviewed these files"
        case (_, .approve): ownMerge ? "Merge \(pending.expect)" : "Approve \(pending.expect)"
        case (_, .turnOn), (_, .turnOnRepo): "Turn on"
        case (_, .turnOff): "Turn off"
        case (_, .update): "Update to \(pending.expect)"
        case (_, .agentCreate): "Continue"
        }
    }
}

/// Changed files grouped by what they can do: workflows (red), human-owned (amber), agent-written.
struct FileGroups: View {
    let files: [PlannedFile]

    var body: some View {
        let workflows = files.filter(\.isWorkflow)
        let humanOwned = files.filter(\.isHumanOwned)
        let agent = files.filter { !$0.isWorkflow && !$0.isHumanOwned }
        VStack(alignment: .leading, spacing: 12) {
            if !workflows.isEmpty {
                group(title: "Workflows and guardrails · can change what CI enforces", color: Palette.danger, files: workflows)
            }
            if !humanOwned.isEmpty {
                group(title: "Human-owned · yours from now on", color: Palette.warning, files: humanOwned)
            }
            if !agent.isEmpty {
                group(title: "Written by the agent", color: Palette.textSecondary, files: agent)
            }
        }
    }

    private func group(title: String, color: Color, files: [PlannedFile]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                    Spacer()
                    Text("\(files.count)").font(.caption).foregroundStyle(Palette.textSecondary)
                }
                ForEach(files, id: \.path) { file in
                    Text(displaySafe(file.path))
                        .font(.mono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct WorkflowWarning: View {
    let files: [PlannedFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This PR changes workflows or guardrails", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("These files decide what CI checks. Approve only if you read these changes on GitHub:")
                .font(.system(size: 12))
            ForEach(files, id: \.path) { Text(displaySafe($0.path)).font(.mono) }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Palette.dangerFill))
    }
}

struct ResultCard: View {
    let symbol: String
    let color: Color
    let title: String
    let message: String

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .medium))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct Bullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(Palette.textSecondary)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What an update brings: versions and the new commits of the kit repository.
struct UpdatePlanCard: View {
    let update: UpdatePlan

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Version \(update.fromVersion) → \(update.toVersion)").font(.system(size: 15, weight: .medium))
                HStack(spacing: 8) {
                    SHABadge(sha: update.shortTo)
                    Text("exactly this commit of the kit's main").font(.caption).foregroundStyle(Palette.textSecondary)
                }
                Text("Updates the kit install, registers its skills and hooks again and rebuilds this app.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(update.commits, id: \.self) { commit in
                        Text(displaySafe(commit)).font(.mono).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
        }
    }
}

/// The agent App is registered in the browser; the app only shows what happens there.
struct AgentCreateCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for GitHub in your browser…").font(.system(size: 13, weight: .medium))
                }
                Text("Click \"Create GitHub App\" there, then come back. The App may write contents and pull requests only: no workflows, administration or statuses.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
