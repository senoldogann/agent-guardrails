import AppKit
import SwiftUI

/// Monochrome tokens with color only for meaning (danger, warning, success); light and dark variants. The
/// window is translucent (Liquid Glass and the desktop show through), so surfaces are tinted veils over it:
/// opaque enough that text on them keeps its contrast, clear enough to read as layers of glass.
enum Palette {
    static let surface = Color(light: 0xFFFFFF, lightAlpha: 0.78, dark: 0xFFFFFF, darkAlpha: 0.06)
    static let surfaceMuted = Color(light: 0x000000, lightAlpha: 0.04, dark: 0xFFFFFF, darkAlpha: 0.08)
    static let hairline = Color(light: 0x000000, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let textPrimary = Color(light: 0x0A0A0A, dark: 0xF5F5F7)
    static let textSecondary = Color(light: 0x6B6B70, dark: 0xA1A1A6)
    /// The one color besides the neutrals: something is wrong (an alarm, a failed check, a destructive action).
    /// Everything else is told by icon shape and words, as Primer, Linear and Claude do.
    static let danger = Color(light: 0xC4372C, dark: 0xEE6B60)
    /// Fill behind white text (destructive buttons): dark enough in both modes for contrast.
    static let dangerFill = Color(light: 0xC4372C, dark: 0xB42318)
    /// Fill of primary buttons and switches behind white: graphite in both modes, set where it is used. The
    /// asset catalog's AccentColor is a light gray in light mode, because macOS draws the sidebar selection in
    /// it (`.tint` does not reach the selection) and a graphite row reads as black; plain glass buttons take
    /// that light accent too, so no window sets this tint for all its controls.
    static let accent = Color(light: 0x3F3F46, dark: 0x4C4C52)
}

enum Metrics {
    static let windowPadding: CGFloat = 24
    static let popoverPadding: CGFloat = 16
    static let cardRadius: CGFloat = 14
    static let rowRadius: CGFloat = 10
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(light: light, lightAlpha: 1, dark: dark, darkAlpha: 1)
    }

    init(light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light).withAlphaComponent(isDark ? darkAlpha : lightAlpha)
            })
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    /// A page's title: one size for every page.
    static let displayTitle = Font.system(size: 22, weight: .semibold)
    /// A group's heading inside a page: small, in sentence case, never uppercased.
    static let sectionTitle = Font.system(size: 12, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
}

extension View {
    /// The one primary action of a screen: prominent Liquid Glass in graphite, so the system keeps its white
    /// label readable in light, dark and inactive windows.
    func primaryAction() -> some View {
        buttonStyle(.glassProminent).tint(Palette.accent)
    }

    /// Secondary actions: clear Liquid Glass.
    func secondaryAction() -> some View {
        buttonStyle(.glass)
    }

    /// The one destructive action (turn off, restore after an alarm): prominent glass in red.
    func destructiveAction() -> some View {
        buttonStyle(.glassProminent).tint(Palette.dangerFill)
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.sectionTitle)
            .foregroundStyle(Palette.textSecondary)
    }
}

/// A commit SHA in a monospaced capsule, the thing the owner approves.
struct SHABadge: View {
    let sha: String

    var body: some View {
        Text(sha)
            .font(.mono)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.surfaceMuted))
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .textSelection(.enabled)
    }
}

/// Opaque card: everything the owner must read sits on these, never on glass.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.hairline))
    }
}

/// An alarm in the CLI's own words: a red alert icon on a quiet surface, so the words stay easy to read.
struct AlarmBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            OcticonImage(icon: .alert, size: 14).foregroundStyle(Palette.danger).padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surfaceMuted))
        .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.hairline))
    }
}

/// Every page is one centered column this wide at most, as in Claude and Linear: lines stay readable in a
/// full-screen window, and every page lines up with the others.
let pageWidth: CGFloat = 760

/// Rows of one kind in a single container, split by hairlines, instead of a card per row.
struct RowGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.hairline))
    }
}
