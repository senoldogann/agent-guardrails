import GuardrailsCore
import SwiftUI

/// "+12 −3 · 4 files": the size of a PR's change.
struct DiffStatsLabel: View {
    let diff: Loadable<DiffStats>

    var body: some View {
        if case .loaded(let stats) = diff {
            HStack(spacing: 6) {
                Text("+\(stats.additions)").foregroundStyle(Palette.textPrimary)
                Text("−\(stats.deletions)").foregroundStyle(Palette.textSecondary)
                Text("· \(stats.changedFiles == 1 ? "1 file" : "\(stats.changedFiles) files")")
                    .foregroundStyle(Palette.textSecondary)
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }
}

/// Every check run on the commit the owner approves, failed ones first, then what each kit gate ran.
struct ChecksCard: View {
    let pr: PullRequestPlan
    let evidence: PullRequestEvidence

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SectionLabel(text: "Checks")
                    SHABadge(sha: pr.shortSHA)
                    Spacer()
                    if evidence.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            Task { await evidence.load(pr) }
                        } label: {
                            OcticonImage(icon: .sync, size: 14)
                        }
                        .buttonStyle(.borderless)
                        .help("Load the checks again")
                        .accessibilityLabel("Load the checks again")
                    }
                }
                switch evidence.checks {
                case .loading:
                    Text("Loading checks from GitHub…").font(.caption).foregroundStyle(Palette.textSecondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(Palette.danger).textSelection(.enabled)
                case .loaded(let runs) where runs.isEmpty:
                    Text("No checks ran on this commit.").font(.caption).foregroundStyle(Palette.textSecondary)
                case .loaded(let runs):
                    let replaced = ChecksReading(.loaded(runs)).replacedIDs
                    ForEach(runs) { run in
                        CheckRow(run: run, replaced: replaced.contains(run.id))
                        if run.isKitGate, let gate = evidence.gates[run.id] {
                            GateDetail(gate: gate).padding(.leading, 26)
                        }
                    }
                }
            }
        }
    }
}

/// One check run. A run a newer run of the same name replaced (a rerun, or the guard's cancelled run) is listed with
/// what it was, but not as a failure: the chain counts the newer run, as the CLI's inbox and GitHub's required checks
/// do. A real failure of a run named guard is never shown as replaced.
struct CheckRow: View {
    let run: CheckRun
    let replaced: Bool

    var body: some View {
        HStack(spacing: 10) {
            CheckSymbol(outcome: replaced ? .skipped : run.outcome)
            Text(displaySafe(run.name)).font(.system(size: 13, weight: .medium))
            if replaced {
                Text("\(ChecksReading.word(run)), replaced by a newer run").font(.caption).foregroundStyle(Palette.textSecondary)
            } else if run.outcome == .skipped {
                // Skipped and neutral share the symbol; the word tells them apart.
                Text(ChecksReading.word(run)).font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 8)
            if let duration = run.duration {
                Text(shortDuration(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)
            }
            Button {
                openInBrowser(run.htmlURL)
            } label: {
                OcticonImage(icon: .linkExternal, size: 14)
            }
            .buttonStyle(.borderless)
            .help("Open this check on GitHub")
            .accessibilityLabel("Open \(displaySafe(run.name)) on GitHub")
        }
    }
}

struct CheckSymbol: View {
    let outcome: CheckOutcome

    var body: some View {
        switch outcome {
        case .passed:
            OcticonImage(icon: .checkCircle, size: 14).foregroundStyle(Palette.textSecondary).frame(width: 16)
        case .failed:
            OcticonImage(icon: .xCircle, size: 14).foregroundStyle(Palette.danger).frame(width: 16)
        case .running:
            ProgressView().controlSize(.mini).frame(width: 16)
        case .skipped:
            OcticonImage(icon: .skip, size: 14).foregroundStyle(Palette.textSecondary).frame(width: 16)
        }
    }
}

/// The gates and steps one `checks-<lang>` job ran, and its mutation verdict.
struct GateDetail: View {
    let gate: Loadable<GateReport>

    var body: some View {
        switch gate {
        case .loading:
            Text("Reading the CI log…").font(.caption).foregroundStyle(Palette.textSecondary)
        case .failed(let message):
            Text("Could not read the CI log: \(message)").font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(3)
        case .loaded(let report):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(report.gates.enumerated()), id: \.offset) { _, gate in
                    GateSteps(gate: gate)
                }
                MutationLine(outcome: report.mutation)
                Text("Read from the CI log; the check's own result is what counts.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surfaceMuted))
        }
    }
}

struct GateSteps: View {
    let gate: Gate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(Array(gate.steps.enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 5) {
                        OcticonImage(icon: step.passed ? .check : (step.exitCode == nil ? .kebabHorizontal : .x), size: 12)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(step.passed ? Palette.textSecondary : Palette.danger)
                        Text(displaySafe(step.name)).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    }
                    .help(step.exitCode.map { "exit \($0)" } ?? "the log ends before this step finished")
                }
            }
        }
    }

    private var title: String {
        switch gate.kind {
        case .full: "Full gate"
        case .spec(let ticket): "Spec gate · \(displaySafe(ticket)) (locked tests fail on the stubs)"
        case .draft(let ticket): "Draft gate · \(displaySafe(ticket)) (spec not locked yet)"
        }
    }
}

/// "Mutation · 46 of 46 mutants killed", with a bar; survivors in red.
struct MutationLine: View {
    let outcome: MutationOutcome

    var body: some View {
        switch outcome {
        case .judged(let counts):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Mutation").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Text(verdict(counts))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(counts.failing > 0 ? Palette.danger : Palette.textPrimary)
                }
                ProgressView(value: Double(counts.killed + counts.accepted), total: Double(max(counts.counted, 1)))
                    .tint(counts.failing > 0 ? Palette.danger : Palette.textSecondary)
            }
        case .nothingToMutate:
            note("Mutation · no changed source to mutate")
        case .unfinished:
            note("Mutation · stopped before its verdict").foregroundStyle(Palette.danger)
        case .notRun:
            note("Mutation · not run in this job")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
    }

    private func verdict(_ counts: MutationCounts) -> String {
        var parts = ["\(counts.killed + counts.accepted) of \(counts.counted) killed"]
        if counts.accepted > 0 { parts.append("\(counts.accepted) accepted") }
        if counts.failing > 0 { parts.append("\(counts.failing) survived") }
        return parts.joined(separator: " · ")
    }
}

/// The ticket's acceptance criteria and properties as committed in this PR.
struct SpecCard: View {
    let spec: Loadable<SpecDocuments>
    @State private var showsCriteria = true
    @State private var showsProperties = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                switch spec {
                case .loading:
                    SectionLabel(text: "Spec")
                    Text("Loading the spec…").font(.caption).foregroundStyle(Palette.textSecondary)
                case .failed(let message):
                    SectionLabel(text: "Spec")
                    Text(message).font(.caption).foregroundStyle(Palette.danger).textSelection(.enabled)
                case .loaded(let documents):
                    HStack {
                        SectionLabel(text: "Spec \(documents.ticket)")
                        Spacer()
                        Button {
                            openInBrowser(documents.url)
                        } label: {
                            GitHubLabel(title: "Open spec")
                        }
                        .secondaryAction()
                        .controlSize(.small)
                    }
                    SpecDocument(title: "Acceptance criteria", text: documents.acceptanceCriteria, isExpanded: $showsCriteria)
                    SpecDocument(title: "Properties", text: documents.properties, isExpanded: $showsProperties)
                }
            }
        }
    }
}

struct SpecDocument: View {
    let title: String
    let text: String?
    @Binding var isExpanded: Bool

    var body: some View {
        if let text {
            DisclosureGroup(title, isExpanded: $isExpanded) {
                ScrollView {
                    // Plain text on purpose: the agent wrote it, so links are not made clickable.
                    Text(text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surfaceMuted))
            }
            .font(.system(size: 12, weight: .medium))
        } else {
            Text("\(title): not in this PR").font(.caption).foregroundStyle(Palette.textSecondary)
        }
    }
}
