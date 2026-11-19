import AppKit
import SwiftUI

/// Monochrome tokens with one color for meaning (danger); light and dark variants. In the glass style the
/// window is translucent, so surfaces are tinted veils over it: opaque enough that text on them keeps its
/// contrast, clear enough to read as layers of glass. Over the solid style's canvas the same veils read as
/// flat white (light) or dark gray (dark) panels.
enum Palette {
    static let surface = Color(light: 0xFFFFFF, lightAlpha: 0.78, dark: 0xFFFFFF, darkAlpha: 0.06)
    static let surfaceMuted = Color(light: 0x000000, lightAlpha: 0.04, dark: 0xFFFFFF, darkAlpha: 0.08)
    /// Borders and dividers: as faint as still reads as an edge, so groups separate without lines drawing the eye.
    static let hairline = Color(light: 0x000000, lightAlpha: 0.055, dark: 0xFFFFFF, darkAlpha: 0.07)
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

    /// The glass style's veil over the window material. The material alone takes the color of what is behind
    /// the window, so a light-mode window over a dark one turned a muddy gray (more so while inactive); the
    /// veil keeps the page light in light mode and dark in dark mode, with the desktop still showing through.
    static let glassVeil = Color(light: 0xFAFAFB, lightAlpha: 0.72, dark: 0x111113, darkAlpha: 0.5)
    /// The solid style's window: near black in dark mode, a light gray close to white in light mode.
    static let canvas = Color(light: 0xF5F5F6, dark: 0x0E0E10)
    /// The solid style's sidebar: one step away from the page, darker in both modes.
    static let sidebar = Color(light: 0xECECEE, dark: 0x080809)
    /// The solid style's raised controls (selected tab, secondary buttons, panels): white on light, gray on dark.
    static let control = Color(light: 0xFFFFFF, dark: 0x1C1C1F)
    /// The solid style's primary button: black on light and white on dark, with the opposite label.
    static let inverseFill = Color(light: 0x111113, dark: 0xF2F2F3)
    static let inverseText = Color(light: 0xFFFFFF, dark: 0x0E0E10)
}

/// How the app is drawn: Liquid Glass over the desktop, or solid surfaces in black and white.
enum AppStyle: String, CaseIterable, Identifiable {
    case glass
    case solid

    static let key = "appStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: "Liquid Glass"
        case .solid: "Solid"
        }
    }
}

/// Light or dark for the whole app (window and menu bar panel), or whatever macOS uses.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let key = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Applies the owner's appearance choice to every window of the app.
@MainActor
func applyAppearance(_ choice: AppearanceChoice) {
    NSApplication.shared.appearance = choice.nsAppearance
}

/// The stored appearance choice; an unknown or missing value is the system's.
@MainActor
func storedAppearance() -> AppearanceChoice {
    AppearanceChoice(rawValue: UserDefaults.standard.string(forKey: AppearanceChoice.key) ?? "") ?? .system
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
    /// label readable in light, dark and inactive windows; black (white in dark mode) in the solid style.
    func primaryAction() -> some View {
        modifier(PrimaryActionStyle())
    }

    /// Secondary actions: clear Liquid Glass, or a raised control with a hairline in the solid style.
    func secondaryAction() -> some View {
        modifier(SecondaryActionStyle())
    }

    /// The one destructive action (turn off, restore after an alarm): red, as glass or solid.
    func destructiveAction() -> some View {
        modifier(DestructiveActionStyle())
    }

    /// A panel that floats over the page (the agent panel): a piece of glass, or a raised solid control.
    func floatingPanel(cornerRadius: CGFloat) -> some View {
        modifier(FloatingPanelStyle(cornerRadius: cornerRadius))
    }

    /// A bar along a page's edge (the review's action bar): the system bar material, or the solid page color
    /// with a hairline on top.
    func edgeBar() -> some View {
        modifier(EdgeBarStyle())
    }
}

struct PrimaryActionStyle: ViewModifier {
    @AppStorage(AppStyle.key) private var style = AppStyle.glass

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .glass: content.buttonStyle(.glassProminent).tint(Palette.accent)
        case .solid: content.buttonStyle(SolidButtonStyle(fill: Palette.inverseFill, label: Palette.inverseText, border: .clear))
        }
    }
}

struct SecondaryActionStyle: ViewModifier {
    @AppStorage(AppStyle.key) private var style = AppStyle.glass

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .glass: content.buttonStyle(.glass)
        case .solid: content.buttonStyle(SolidButtonStyle(fill: Palette.control, label: Palette.textPrimary, border: Palette.hairline))
        }
    }
}

struct DestructiveActionStyle: ViewModifier {
    @AppStorage(AppStyle.key) private var style = AppStyle.glass

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .glass: content.buttonStyle(.glassProminent).tint(Palette.dangerFill)
        case .solid: content.buttonStyle(SolidButtonStyle(fill: Palette.dangerFill, label: .white, border: .clear))
        }
    }
}

struct FloatingPanelStyle: ViewModifier {
    let cornerRadius: CGFloat
    @AppStorage(AppStyle.key) private var style = AppStyle.glass

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .glass: content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        case .solid:
            content
                .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Palette.control))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Palette.hairline))
        }
    }
}

struct EdgeBarStyle: ViewModifier {
    @AppStorage(AppStyle.key) private var style = AppStyle.glass

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .glass:
            content
                .background(.bar)
                .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        case .solid:
            content
                .background(Palette.canvas)
                .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
    }
}

/// A flat button for the solid style: a rounded rectangle in one fill, no gradient, no glass.
struct SolidButtonStyle: ButtonStyle {
    let fill: Color
    let label: Color
    let border: Color

    func makeBody(configuration: Configuration) -> some View {
        SolidButtonBody(configuration: configuration, fill: fill, label: label, border: border)
    }
}

private struct SolidButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    let label: Color
    let border: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let small = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: small ? 6 : 7)
        configuration.label
            .font(.system(size: small ? 11 : 13, weight: .medium))
            .foregroundStyle(label)
            .padding(.horizontal, small ? 8 : 12)
            .frame(minHeight: small ? 22 : 28)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
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
