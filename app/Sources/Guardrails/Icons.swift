import AppKit
import SwiftUI

/// GitHub's own icons, from the Octicons SVGs (16 × 16 grid).
enum Octicon {
    case markGitHub
    case pullRequest

    /// Template images, so they take the surrounding text color in light and dark mode.
    @MainActor fileprivate var image: NSImage {
        switch self {
        case .markGitHub: Self.markGitHubImage
        case .pullRequest: Self.pullRequestImage
        }
    }

    @MainActor private static let markGitHubImage = templateImage(svgPath: markGitHubPath, name: "mark-github")
    @MainActor private static let pullRequestImage = templateImage(svgPath: pullRequestPath, name: "git-pull-request")
}

/// An Octicon at a given size.
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

/// A button label with the GitHub mark in front of the title.
struct GitHubLabel: View {
    let title: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            OcticonImage(icon: .markGitHub, size: 14)
        }
        .labelStyle(.titleAndIcon)
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

private let markGitHubPath = """
    M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49\
    -2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07\
    -.52.28-.87.51-1.06-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82\
    .64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15\
     0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8\
    c0-4.42-3.58-8-8-8z
    """

private let pullRequestPath = """
    M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25Zm5.677-.177\
    L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1\
    v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z\
    m0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z
    """
