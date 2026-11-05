import AppKit
import SwiftUI

/// Monochrome tokens with color only for meaning (danger, warning, success); light and dark variants.
enum Palette {
    static let canvas = Color(light: 0xFAFAFA, dark: 0x0B0B0C)
    static let surface = Color(light: 0xFFFFFF, dark: 0x161618)
    static let surfaceMuted = Color(light: 0xF4F4F5, dark: 0x1F1F22)
    static let hairline = Color(light: 0xE7E7E9, dark: 0x2A2A2E)
    static let textPrimary = Color(light: 0x0A0A0A, dark: 0xF5F5F7)
    static let textSecondary = Color(light: 0x6B6B70, dark: 0xA1A1A6)
    static let inverseText = Color(light: 0xFFFFFF, dark: 0x0A0A0A)
    static let danger = Color(light: 0xD92D20, dark: 0xF97066)
    /// Fill behind white text (alarms, destructive buttons): dark enough in both modes for contrast.
    static let dangerFill = Color(light: 0xD92D20, dark: 0xB42318)
    static let warning = Color(light: 0xB54708, dark: 0xFDB022)
    static let success = Color(light: 0x067647, dark: 0x47CD89)
}

enum Metrics {
    static let windowPadding: CGFloat = 24
    static let popoverPadding: CGFloat = 16
    static let cardRadius: CGFloat = 14
    static let rowRadius: CGFloat = 10
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light)
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
    static let displayTitle = Font.system(size: 22, weight: .medium)
    static let sectionTitle = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
}

/// Black capsule with inverted text: the one primary action on a screen.
struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .foregroundStyle(Palette.inverseText)
            .background(Capsule().fill(Palette.textPrimary))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Hairline capsule for secondary actions.
struct SecondaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(Palette.textPrimary)
            .background(Capsule().fill(Palette.surfaceMuted))
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Red capsule for the one destructive action (turn off).
struct DestructivePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(Capsule().fill(Palette.dangerFill))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.sectionTitle)
            .tracking(0.6)
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

/// A red banner with the CLI's own alarm sentence.
struct AlarmBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.dangerFill))
    }
}
