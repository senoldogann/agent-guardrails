import GuardrailsCore
import SwiftUI

/// The review tab of one action. Everything the owner reads comes from the CLI's plan event and sits on
/// opaque surfaces; only the bottom action bar is glass. The session outlives the view, so switching tabs
/// keeps the run and its loaded checks.
struct ReviewView: View {
    let session: ReviewSession
    let close: () -> Void
    @State private var showsLog = false

    private var request: ActionRequest { session.request }
    private var model: ActionModel? { session.action }
    private var evidence: PullRequestEvidence { session.evidence }

    var body: some View {
        Group {
            if let model, let pr = model.plan?.pullRequest {
                decisionBoard(pr, model: model)
            } else {
                scrollingBody
            }
        }
        .task(id: model?.plan?.pullRequest?.sha) {
            if let pr = model?.plan?.pullRequest, evidence.loadedSHA != pr.sha { await evidence.load(pr) }
        }
    }

    /// Every other kind of action: the plan, the result and the guarded buttons in one column.
    private var scrollingBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(request.windowTitle).font(.displayTitle)
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
        case .approve, .turnOn:
            // Drawn by decisionBoard(_:model:), which needs the whole window: the chain, the evidence and the
            // commit the approval lands on.
            EmptyView()
        case .turnOnRepo(let repoPlan):
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(repoPlan.repo).font(.system(size: 15, weight: .medium))
                    Text("The kit files on \(repoPlan.branch) match your installed kit. Turning on applies the ruleset: merges then wait for the checks and your approval.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textSecondary)
                    if repoPlan.withMergeQueue {
                        MergeQueuePlanNote()
                    }
                }
            }
        case .turnOff(let removal):
            removalPlan(removal)
        }
    }

    // MARK: decision board

    /// A pull request's review as one board: the chain of gates on top, the evidence on the left and the commit
    /// the approval lands on, with the one button that closes the last link, on the right.
    private func decisionBoard(_ pr: PullRequestPlan, model: ActionModel) -> some View {
        VStack(spacing: 0) {
            boardHeader(pr, model: model)
            GateRail(chain: chain(model))
                .padding(.horizontal, Metrics.windowPadding)
                .padding(.bottom, 14)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        statusSection(model)
                        ChecksCard(pr: pr, evidence: evidence)
                        if let spec = evidence.spec { SpecCard(spec: spec) }
                        if !pr.lockScopeChanges.isEmpty { LockScopeGroups(changes: pr.lockScopeChanges) }
                        FileGroups(files: pr.files)
                        logSection(model)
                    }
                    .padding(Metrics.windowPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Rectangle().fill(Palette.hairline).frame(width: 1)
                ScrollView {
                    boardDecision(pr, model: model)
                        .padding(Metrics.windowPadding)
                }
                .frame(width: 322)
            }
        }
    }

    private func boardHeader(_ pr: PullRequestPlan, model: ActionModel) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                OcticonImage(icon: .pullRequest, size: 12)
                    .foregroundStyle(Palette.textSecondary)
                Text("\(pr.repo) · PR #\(pr.pr)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                if model.isRunning {
                    Button("Cancel") { model.cancel() }
                        .secondaryAction()
                        .keyboardShortcut(.cancelAction)
                        .disabled(!model.canCancel)
                } else {
                    Button("Close", action: close)
                        .secondaryAction()
                        .keyboardShortcut(.cancelAction)
                }
            }
            Text(displaySafe(pr.title))
                .font(.system(size: 19, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(pr.shortSHA)
                    .font(.mono)
                    .textSelection(.enabled)
                if case .loaded(let now) = evidence.snapshot, now.head.sha == pr.sha {
                    DiffStatsLabel(diff: .loaded(now.stats))
                }
                if case .loaded(let now) = evidence.snapshot {
                    Text("\(now.base.ref) ← \(now.head.ref)")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// The commit column: the SHA as the object of the decision, what the chain already proved, and the button.
    private func boardDecision(_ pr: PullRequestPlan, model: ActionModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("You approve exactly this commit")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                    Text(pr.shortSHA)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel("Commit \(pr.sha)")
                }

                noticeLines(pr, model: model)

                Rectangle().fill(Palette.hairline).frame(height: 1)

                checksSummary

                boardAction(model)

                actionHint(model, alignment: .leading)
            }
        }
    }

    /// The one button. When the change touches files the owner must read first, the button is the diff, not the
    /// approval, so nobody wonders why Approve does not react.
    @ViewBuilder
    private func boardAction(_ model: ActionModel) -> some View {
        if mustOpenDiff(model), let pr = model.plan?.pullRequest {
            Button {
                openDiff(pr, model: model)
            } label: {
                OcticonLabel("Open changes on GitHub", icon: .linkExternal)
                    .frame(maxWidth: .infinity)
            }
            .primaryAction()
            .disabled(pr.compareURL == nil)
        } else {
            confirmButton(model, wide: true)
        }
    }

    /// The checks as GuardrailsCore reads them (`ChecksReading`): the rail's guard and checks links and the summary.
    private var checksReading: ChecksReading {
        switch evidence.checks {
        case .loading: ChecksReading(.loading)
        case .failed(let message): ChecksReading(.unavailable(message))
        case .loaded(let runs): ChecksReading(.loaded(runs))
        }
    }

    /// The chain of gates for this run: the plan, the checks and where the action stands (`pullRequestChain`).
    private func chain(_ model: ActionModel) -> Chain {
        guard let plan = model.plan else { return Chain(links: [], missing: nil) }
        var ticket: String?
        if case .loaded(let spec) = evidence.spec { ticket = spec.ticket }
        return pullRequestChain(plan: plan, specTicket: ticket, checks: checksReading, progress: model.progress)
    }

    /// What the checks on this commit add up to, in one line: passed only when every run passed.
    private var checksSummary: some View {
        let reading = checksReading
        let icon: Octicon =
            switch reading.tone {
            case .problem: .alert
            case .waiting: .clock
            case .passed: .checkCircle
            case .incomplete: .skip
            }
        return OcticonLabel(reading.summary, icon: icon)
            .font(.system(size: 12))
            .foregroundStyle(reading.tone == .problem ? Palette.danger : Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What this approval means for this PR: a moved head, the owner's own push, a kit that already matches.
    @ViewBuilder
    private func noticeLines(_ pr: PullRequestPlan, model: ActionModel) -> some View {
        if case .failed(let message) = evidence.snapshot {
            Text("Could not read the PR from GitHub, so the diff link waits: \(message). Load again with the button under Checks.")
                .font(.caption)
                .foregroundStyle(Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if case .loaded(let now) = evidence.snapshot, now.head.sha != pr.sha {
            OcticonLabel("The PR moved to \(now.head.sha.prefix(7)) after this check. Close this and review the new commit.", icon: .alert)
                .font(.system(size: 12))
                .foregroundStyle(Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        if case .turnOn = model.plan {
            OcticonLabel("Kit files match your installed kit", icon: .checkCircle)
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
            if pr.mergeQueue == true { MergeQueuePlanNote() }
        }
        if pr.isOwnPush {
            OcticonLabel(displaySafe(pr.ownPushNote), icon: .gitMerge)
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if pr.isOwnQueueEntry {
            OcticonLabel("Your own PR: GitHub does not take your review, so this adds it to the merge queue now. Your admin bypass skips the review, not the checks.", icon: .gitMerge)
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if pr.isOwnMerge {
            OcticonLabel("Your own PR: GitHub does not take your review, so this merges it now. Your admin bypass skips the review, not the checks.", icon: .gitMerge)
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    Text(note).font(.caption).foregroundStyle(Palette.textSecondary)
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
        case .awaitingConfirmation(let pending) where pending.step == .unlock:
            UnlockWarning(changes: model.plan?.pullRequest?.droppedLockedFiles ?? [])
        case .working:
            Card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Working… do not close this window.").font(.system(size: 13))
                }
            }
        case .succeeded:
            ResultCard(
                symbol: .checkCircle, color: Palette.textSecondary, title: successTitle(model),
                message: successMessage(model))
        case .failed(let message):
            ResultCard(symbol: .xCircle, color: Palette.danger, title: "Stopped", message: message)
        case .cancelled:
            ResultCard(symbol: .skip, color: Palette.textSecondary, title: "Cancelled", message: "Nothing was changed.")
        case .preparing, .awaitingConfirmation, .verifyingOwner:
            if let problem = model.ownerCheckProblem {
                StatusPanel(symbol: .passkey, title: "Not confirmed", message: problem)
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
        case .approve where model.plan?.pullRequest?.isOwnQueueEntry == true: "Added to the merge queue"
        case .approve: model.plan?.pullRequest?.isOwnMerge == true ? "Merged" : "Approved"
        case .turnOn, .turnOnRepo: "Guardrails are on"
        case .turnOnMergeQueue: "Merge queue is on"
        case .turnOff: "Guardrails are off"
        case .update: "Kit updated"
        case .agentCreate: "Agent App registered"
        }
    }

    private func successMessage(_ model: ActionModel) -> String {
        switch request.kind {
        case .approve where model.plan?.pullRequest?.isOwnQueueEntry == true:
            "The PR is in the merge queue at exactly the commit you confirmed; it merges when its group passes the checks."
        case .approve where model.plan?.pullRequest?.isOwnMerge == true:
            "The PR is merged at exactly the commit you confirmed."
        case .approve: "The PR merges by itself once its checks pass. A new push needs a new approval."
        case .turnOn, .turnOnRepo: "Ask your agent for /ticket-spec <ID> in this repository."
        case .turnOnMergeQueue: "Approved PRs now merge through the merge queue, which checks them together with the PRs ahead of them."
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
                    .secondaryAction()
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.canCancel)
                } else {
                    Button("Close", action: close)
                        .secondaryAction()
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                actionHint(model)
                if mustOpenDiff(model), let pr = model.plan?.pullRequest {
                    // The next step is the primary button, so nobody wonders why Approve does not react.
                    Button {
                        openDiff(pr, model: model)
                    } label: {
                        OcticonLabel("Open changes on GitHub", icon: .linkExternal)
                    }
                    .primaryAction()
                    .disabled(pr.compareURL == nil)
                } else {
                    confirmButton(model)
                }
            }
            .padding(.horizontal, Metrics.windowPadding)
            .padding(.vertical, 14)
        }
        .edgeBar()
    }

    @ViewBuilder
    /// - Parameter wide: fill the column it sits in (the decision column), instead of hugging its title.
    private func confirmButton(_ model: ActionModel, wide: Bool = false) -> some View {
        switch model.phase {
        case .awaitingConfirmation(let pending):
            let button = Button {
                Task { await model.confirm() }
            } label: {
                OcticonLabel(confirmTitle(pending, ownMerge: model.plan?.pullRequest?.isOwnMerge == true), icon: .passkey)
                    .frame(maxWidth: wide ? .infinity : nil)
            }
            .disabled(prMoved(model))
            .help(prMoved(model) ? "The PR has a newer commit than the one shown here." : "")
            if request.kind == .turnOff {
                button.destructiveAction()
            } else {
                button.primaryAction()
            }
        case .verifyingOwner:
            ProgressView().controlSize(.small)
        default:
            EmptyView()
        }
    }

    /// Why the next step is what it is, next to its button.
    @ViewBuilder
    private func actionHint(_ model: ActionModel, alignment: TextAlignment = .trailing) -> some View {
        if prMoved(model) {
            OcticonLabel("The PR moved on. Close this and review the new commit.", icon: .alert)
                .font(.system(size: 12))
                .foregroundStyle(Palette.danger)
        } else if mustOpenDiff(model) {
            Text("Workflow, guardrail, human-owned or spec-locked files change. Look at them before you approve.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.needsDiffReview, model.diffOpened, awaitsCommit(model) {
            OcticonLabel("Changes opened on GitHub", icon: .check)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
        }
    }

    /// The first confirmation waits on the commit itself (later ones confirm workflows or dropped spec locks).
    private func awaitsCommit(_ model: ActionModel) -> Bool {
        if case .awaitingConfirmation(let pending) = model.phase { return pending.step == .commit }
        return false
    }

    /// Sensitive files change and their diff was not opened yet: approving waits for that.
    private func mustOpenDiff(_ model: ActionModel) -> Bool {
        model.needsDiffReview && !model.diffOpened && awaitsCommit(model)
    }

    /// GitHub reports a newer head than the commit this review shows.
    private func prMoved(_ model: ActionModel) -> Bool {
        guard case .loaded(let now) = evidence.snapshot, let pr = model.plan?.pullRequest else { return false }
        return now.head.sha != pr.sha
    }

    private func openDiff(_ pr: PullRequestPlan, model: ActionModel) {
        guard let compareURL = pr.compareURL else { return }
        openInBrowser(compareURL)
        model.markDiffOpened()
    }

    private func confirmTitle(_ pending: ConfirmRequest, ownMerge: Bool) -> String {
        switch (pending.step, request.kind) {
        case (.workflows, _), (.unlock, _): "I reviewed these files"
        case (_, .approve): ownMerge ? "Merge \(pending.expect)" : "Approve \(pending.expect)"
        case (_, .turnOn), (_, .turnOnRepo), (_, .turnOnMergeQueue): "Turn on"
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
                group(title: "Human-owned · yours from now on", color: Palette.textSecondary, files: humanOwned)
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
            OcticonLabel("This PR changes workflows or guardrails", icon: .alert)
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

/// The files a re-lock stops or starts locking, in the plan card's file style: no longer locked (red, a separate
/// confirmation follows) and newly locked.
struct LockScopeGroups: View {
    let changes: [LockScopeChange]

    var body: some View {
        let dropped = changes.filter(\.isDropped)
        let added = changes.filter { !$0.isDropped }
        VStack(alignment: .leading, spacing: 12) {
            if !dropped.isEmpty {
                group(title: "No longer spec-locked · the agent could change these without a new lock", color: Palette.danger, changes: dropped)
            }
            if !added.isEmpty {
                group(title: "Newly spec-locked", color: Palette.textSecondary, changes: added)
            }
        }
    }

    private func group(title: String, color: Color, changes: [LockScopeChange]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                    Spacer()
                    Text("\(changes.count)").font(.caption).foregroundStyle(Palette.textSecondary)
                }
                ForEach(changes, id: \.self) { change in
                    LockScopeRow(change: change)
                }
            }
        }
    }
}

private struct LockScopeRow: View {
    let change: LockScopeChange

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(displaySafe(change.path))
                .font(.mono)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(displaySafe(change.lock)).font(.caption).foregroundStyle(Palette.textSecondary)
        }
    }
}

struct UnlockWarning: View {
    let changes: [LockScopeChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OcticonLabel("This PR stops spec-locking files", icon: .alert)
                .font(.system(size: 13, weight: .semibold))
            Text("After the merge the agent could change these without a new spec lock. Confirm only if you meant to drop them from the lock:")
                .font(.system(size: 12))
            ForEach(changes, id: \.self) { Text(displaySafe($0.path)).font(.mono) }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Palette.dangerFill))
    }
}

struct ResultCard: View {
    let symbol: Octicon
    let color: Color
    let title: String
    let message: String

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                OcticonImage(icon: symbol, size: 14).font(.system(size: 20)).foregroundStyle(color)
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

/// What `on --merge-queue` adds, in the plan card: the queue's settings, so the owner sees them before confirming.
struct MergeQueuePlanNote: View {
    var body: some View {
        OcticonLabel(
            "Adds the merge queue: approved PRs are squashed and checked together with the PRs ahead of them; each must pass every check, up to 3 per group.",
            icon: .gitMerge
        )
        .font(.caption)
        .foregroundStyle(Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
