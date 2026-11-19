import GuardrailsCore
import SwiftUI

/// One link of the chain a merge passes: the spec, the guard, the checks, the owner's approval, the merge.
/// The rail draws the whole chain at once, so "what is still missing" is read, not worked out.
struct GateLink: Identifiable, Equatable {
    enum State: Equatable {
        /// Proved: the link's own evidence passed.
        case done
        /// Where the owner stands now.
        case now
        /// Broken: something failed and blocks the rest.
        case failed
        /// Not reached yet.
        case pending
    }

    let id: String
    let title: String
    let detail: String
    let icon: Octicon
    let state: State
}

/// The chain as one rail, with the sentence that names what is still missing at its end.
struct GateRail: View {
    let links: [GateLink]
    var verdict: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                if index > 0 {
                    Connector(solid: links[index - 1].state == .done, broken: link.state == .failed)
                }
                GateNode(link: link)
            }
            Spacer(minLength: 12)
            if let verdict, !verdict.isEmpty {
                HStack(spacing: 5) {
                    Text("Still missing:")
                        .foregroundStyle(Palette.textSecondary)
                    Text(verdict)
                        .foregroundStyle(Palette.textPrimary)
                }
                .font(.system(size: 11.5))
                .lineLimit(1)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Palette.hairline).frame(width: 1).padding(.vertical, 3)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gates a merge passes")
    }
}

private struct GateNode: View {
    let link: GateLink

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(fill)
                Circle().strokeBorder(border, lineWidth: link.state == .now ? 1.6 : 1.2)
                OcticonImage(icon: link.icon, size: 11)
                    .foregroundStyle(glyph)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(link.title)
                    .font(.system(size: 12, weight: link.state == .now ? .semibold : .medium))
                    .foregroundStyle(link.state == .pending ? Palette.textSecondary : Palette.textPrimary)
                Text(link.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(link.state == .failed ? Palette.danger : Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(link.title): \(link.detail)")
    }

    private var fill: Color {
        switch link.state {
        case .done: Palette.accent
        case .failed: Palette.danger
        case .now, .pending: .clear
        }
    }

    private var border: Color {
        switch link.state {
        case .done, .failed: .clear
        case .now: Palette.textPrimary
        case .pending: Palette.hairline
        }
    }

    private var glyph: Color {
        switch link.state {
        case .done, .failed: .white
        case .now: Palette.textPrimary
        case .pending: Palette.textSecondary
        }
    }
}

private struct Connector: View {
    let solid: Bool
    let broken: Bool

    var body: some View {
        Rectangle()
            .fill(broken ? Palette.danger.opacity(0.55) : solid ? Palette.textPrimary.opacity(0.3) : Palette.hairline)
            .frame(height: 1)
            .frame(minWidth: 10, maxWidth: 26)
            .padding(.horizontal, 7)
            .accessibilityHidden(true)
    }
}

/// Builds the chain a pull request passes from what the CLI's plan and GitHub's evidence prove, and the
/// sentence that names the one link still missing.
@MainActor
enum PullRequestChain {
    static func chain(plan: PullRequestPlan, evidence: PullRequestEvidence) -> ([GateLink], String) {
        var runs: [CheckRun] = []
        if case .loaded(let loaded) = evidence.checks { runs = loaded }

        var links: [GateLink] = []

        if case .loaded(let spec) = evidence.spec {
            links.append(
                GateLink(
                    id: "spec",
                    title: "Spec",
                    detail: "\(spec.ticket) · in this change",
                    icon: .lock,
                    state: .done
                )
            )
        }

        let guardRun = runs.first { $0.name.lowercased().hasPrefix("guard") }
        links.append(
            GateLink(
                id: "guard",
                title: "Guard",
                detail: guardRun.map { $0.name == "Guard" ? outcomeWord($0) : "\($0.name) · \(outcomeWord($0))" } ?? "not run yet",
                icon: .shieldCheck,
                state: guardRun.map(state(of:)) ?? .pending
            )
        )

        let checks = runs.filter { $0.id != guardRun?.id }
        let failed = checks.filter { $0.outcome == .failed }
        let running = checks.filter { $0.outcome == .running }
        let passed = checks.filter { $0.outcome == .passed }
        links.append(
            GateLink(
                id: "checks",
                title: "Checks",
                detail: checks.isEmpty
                    ? "none reported"
                    : failed.isEmpty
                        ? "\(passed.count) of \(checks.count) passed"
                        : "\(failed.count) failing",
                icon: .checkCircle,
                state: failed.isEmpty ? (checks.isEmpty || !running.isEmpty ? .pending : .done) : .failed
            )
        )

        links.append(
            GateLink(
                id: "approval",
                title: "Approval",
                detail: "this commit",
                icon: .passkey,
                state: .now
            )
        )

        links.append(
            GateLink(
                id: "merge",
                title: "Merge",
                detail: plan.isOwnMerge ? "right after the approval" : "after you",
                icon: .gitMerge,
                state: plan.isOwnMerge ? .now : .pending
            )
        )

        return (links, verdict(links))
    }

    /// The one sentence the rail ends with: the first link that is not proved.
    private static func verdict(_ links: [GateLink]) -> String {
        if let failed = links.first(where: { $0.state == .failed }) {
            return "\(failed.title.lowercased()) failed"
        }
        if links.contains(where: { $0.state == .pending && $0.id != "merge" }) {
            return "the checks"
        }
        return "your approval"
    }

    private static func state(of run: CheckRun) -> GateLink.State {
        switch run.outcome {
        case .passed: .done
        case .failed: .failed
        case .running: .now
        case .skipped: .pending
        }
    }

    private static func outcomeWord(_ run: CheckRun) -> String {
        switch run.outcome {
        case .passed: "passed"
        case .failed: "failed"
        case .running: "running"
        case .skipped: "skipped"
        }
    }
}

/// The same rail one level up: what makes one repository's merges guarded, from what the CLI reports about it.
enum RepositoryChain {
    static func chain(_ project: Project) -> ([GateLink], String?) {
        let enforced = project.state == .on || project.state == .alarm
        let detail = enforced ? "installed" : "not installed"
        var links: [GateLink] = [
            GateLink(
                id: "kit",
                title: "Kit",
                detail: detail,
                icon: .box,
                state: project.state == .alarm ? .failed : enforced ? .done : .pending
            ),
            GateLink(
                id: "ruleset",
                title: "Ruleset",
                detail: enforced ? "\(project.branch) · protected" : "\(project.branch) stays open",
                icon: .shieldCheck,
                state: enforced ? .done : .pending
            ),
        ]
        if enforced {
            let statusOnly = project.mode == .status
            links.append(
                GateLink(
                    id: "approval",
                    title: "Approval",
                    detail: statusOnly ? "status only" : "yours, per commit",
                    icon: .passkey,
                    state: statusOnly ? .pending : .done
                )
            )
            if project.organization == true, project.mergeQueue == true {
                links.append(GateLink(id: "queue", title: "Merge queue", detail: "on", icon: .gitMerge, state: .done))
            }
        }
        return (links, verdict(project))
    }

    /// The one link that is not proved, or nothing when the chain is complete.
    private static func verdict(_ project: Project) -> String? {
        switch project.state {
        case .alarm: "an alarm"
        case .on: project.mode == .status ? "your reviews" : nil
        case .ready, .off, .noAdmin, .elsewhere: "turning it on"
        }
    }
}

/// The repository page's chain.
struct RepositoryRail: View {
    let project: Project

    var body: some View {
        let (links, verdict) = RepositoryChain.chain(project)
        GateRail(links: links, verdict: verdict)
    }
}
