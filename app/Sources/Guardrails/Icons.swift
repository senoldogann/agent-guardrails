import AppKit
import SwiftUI

/// Every icon the app draws: GitHub's Octicons (16 × 16 SVG paths in OcticonPaths.swift), as template images in
/// one color, the color of the text around them. No other icon set is used, so the app reads as one system.
enum Octicon: String, CaseIterable {
    case alert
    case apps
    case bell
    case bellSlash = "bell-slash"
    case check
    case checkCircle = "check-circle"
    case chevronDown = "chevron-down"
    case chevronRight = "chevron-right"
    case circle
    case clock
    case comment
    case dash
    case download
    case gear
    case gitBranch = "git-branch"
    case gitCommit = "git-commit"
    case gitMerge = "git-merge"
    case pullRequest = "git-pull-request"
    case pullRequestClosed = "git-pull-request-closed"
    case pullRequestDraft = "git-pull-request-draft"
    case history
    case hourglass
    case inbox
    case info
    case kebabHorizontal = "kebab-horizontal"
    case key
    case linkExternal = "link-external"
    case lock
    case markGitHub = "mark-github"
    case box = "package"
    case passkey = "passkey-fill"
    case person
    case plug
    case repo
    case repoForked = "repo-forked"
    case shield
    case shieldCheck = "shield-check"
    case shieldLock = "shield-lock"
    case shieldX = "shield-x"
    case skip
    case stop
    case sync
    case terminal
    case tools
    case x
    case xCircle = "x-circle"

    /// A template image, decoded once.
    @MainActor var image: NSImage {
        if let cached = Self.images[self] { return cached }
        guard let path = octiconPaths[rawValue] else {
            preconditionFailure("No path data for the \(rawValue) Octicon; regenerate OcticonPaths.swift")
        }
        let decoded = templateImage(svgPath: path, name: rawValue)
        Self.images[self] = decoded
        return decoded
    }

    @MainActor private static var images: [Octicon: NSImage] = [:]
}

/// An Octicon at a given size, in the foreground color.
struct OcticonImage: View {
    let icon: Octicon
    let size: CGFloat

    var body: some View {
        Image(nsImage: icon.image)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A title with an Octicon in front, for buttons, menus and status lines.
struct OcticonLabel: View {
    let title: String
    let icon: Octicon

    init(_ title: String, icon: Octicon) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            OcticonImage(icon: icon, size: 14)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// A button label with the GitHub mark in front of the title.
struct GitHubLabel: View {
    let title: String

    var body: some View {
        OcticonLabel(title, icon: .markGitHub)
    }
}

private func templateImage(svgPath: String, name: String) -> NSImage {
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><path d=""#
        + svgPath + #""/></svg>"#
    guard let image = NSImage(data: Data(svg.utf8)) else {
        preconditionFailure("The bundled \(name) SVG did not decode")
    }
    image.isTemplate = true
    return image
}
