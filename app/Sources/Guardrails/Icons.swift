import AppKit
import SwiftUI

/// GitHub's own icons, from the Octicons SVGs (16 × 16 grid).
enum Octicon {
    case markGitHub
    case pullRequest
    case repo
    case lock
    case repoForked

    /// Template images, so they take the surrounding text color in light and dark mode.
    @MainActor fileprivate var image: NSImage {
        switch self {
        case .markGitHub: Self.markGitHubImage
        case .pullRequest: Self.pullRequestImage
        case .repo: Self.repoImage
        case .lock: Self.lockImage
        case .repoForked: Self.repoForkedImage
        }
    }

    @MainActor private static let markGitHubImage = templateImage(svgPath: markGitHubPath, name: "mark-github")
    @MainActor private static let pullRequestImage = templateImage(svgPath: pullRequestPath, name: "git-pull-request")
    @MainActor private static let repoImage = templateImage(svgPath: repoPath, name: "repo")
    @MainActor private static let lockImage = templateImage(svgPath: lockPath, name: "lock")
    @MainActor private static let repoForkedImage = templateImage(svgPath: repoForkedPath, name: "repo-forked")
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

private let repoPath = """
    M2 2.5A2.5 2.5 0 0 1 4.5 0h8.75a.75.75 0 0 1 .75.75v12.5a.75.75 0 0 1-.75.75h-2.5a.75.75 0 0 1 0-1.5h1.75v-2h-\
    8a1 1 0 0 0-.714 1.7.75.75 0 1 1-1.072 1.05A2.495 2.495 0 0 1 2 11.5Zm10.5-1h-8a1 1 0 0 0-1 1v6.708A2.486 2.48\
    6 0 0 1 4.5 9h8ZM5 12.25a.25.25 0 0 1 .25-.25h3.5a.25.25 0 0 1 .25.25v3.25a.25.25 0 0 1-.4.2l-1.45-1.087a.249.\
    249 0 0 0-.3 0L5.4 15.7a.25.25 0 0 1-.4-.2Z
    """

private let lockPath = """
    M4 4a4 4 0 0 1 8 0v2h.25c.966 0 1.75.784 1.75 1.75v5.5A1.75 1.75 0 0 1 12.25 15h-8.5A1.75 1.75 0 0 1 2 13.25v-\
    5.5C2 6.784 2.784 6 3.75 6H4Zm8.25 3.5h-8.5a.25.25 0 0 0-.25.25v5.5c0 .138.112.25.25.25h8.5a.25.25 0 0 0 .25-.\
    25v-5.5a.25.25 0 0 0-.25-.25ZM10.5 6V4a2.5 2.5 0 1 0-5 0v2Z
    """

private let repoForkedPath = """
    M5 5.372v.878c0 .414.336.75.75.75h4.5a.75.75 0 0 0 .75-.75v-.878a2.25 2.25 0 1 1 1.5 0v.878a2.25 2.25 0 0 1-2.\
    25 2.25h-1.5v2.128a2.251 2.251 0 1 1-1.5 0V8.5h-1.5A2.25 2.25 0 0 1 3.5 6.25v-.878a2.25 2.25 0 1 1 1.5 0ZM5 3.\
    25a.75.75 0 1 0-1.5 0 .75.75 0 0 0 1.5 0Zm6.75.75a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm-3 8.75a.75.75 0 1 0-1\
    .5 0 .75.75 0 0 0 1.5 0Z
    """
