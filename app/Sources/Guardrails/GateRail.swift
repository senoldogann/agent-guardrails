import GuardrailsCore
import SwiftUI

/// One link of the chain a merge passes, as the rail draws it: Core's link (`ChainLink`, decided and tested in
/// GuardrailsCore) with its icon.
struct GateLink: Identifiable, Equatable {
    typealias State = ChainLink.State

    let id: String
    let title: String
    let detail: String
    let icon: Octicon
    let state: State

    init(_ link: ChainLink) {
        id = link.kind.rawValue
        title = link.title
        detail = link.detail
        state = link.state
        icon =
            switch link.kind {
            case .spec: .lock
            case .guardRun: .shieldCheck
            case .checks: .checkCircle
            case .approval: .passkey
            case .merge, .queue: .gitMerge
            case .kit: .box
            case .ruleset: .shieldCheck
            }
    }
}

/// The chain as one rail, with the sentence that names what is still missing at its end.
struct GateRail: View {
    let links: [GateLink]
    let verdict: String?

    init(chain: Chain) {
        links = chain.links.map { GateLink($0) }
        verdict = chain.missing
    }

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
                // A dashed ring: nothing establishes this link either way.
                Circle().strokeBorder(
                    border,
                    style: StrokeStyle(lineWidth: link.state == .now ? 1.6 : 1.2, dash: link.state == .unknown ? [2, 2] : []))
                OcticonImage(icon: link.icon, size: 11)
                    .foregroundStyle(glyph)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(link.title)
                    .font(.system(size: 12, weight: link.state == .now ? .semibold : .medium))
                    .foregroundStyle(link.state == .pending || link.state == .unknown ? Palette.textSecondary : Palette.textPrimary)
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
        case .now, .pending, .unknown: .clear
        }
    }

    private var border: Color {
        switch link.state {
        case .done, .failed: .clear
        case .now: Palette.textPrimary
        case .pending: Palette.hairline
        case .unknown: Palette.textSecondary
        }
    }

    private var glyph: Color {
        switch link.state {
        case .done, .failed: .white
        case .now: Palette.textPrimary
        case .pending, .unknown: Palette.textSecondary
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

/// The repository page's chain, for the project as the app shows it (`shownProject`).
struct RepositoryRail: View {
    let project: Project

    var body: some View {
        GateRail(chain: repositoryChain(project))
    }
}
