import Foundation

/// A page of the main window.
public enum WorkspacePage: Hashable, Sendable {
    case overview
    /// How agent work went across the enforced repositories, read-only.
    case reports
    case repository(String)
    case settings
    case pullRequest(PullRequestRef)
    /// One run of a guardrails action (approve, on, off, update, agent create), by its run id.
    case review(UUID)
    case welcome

    /// Pages the sidebar shows in the browse tab; the others open in tabs of their own.
    public var isBrowsePage: Bool {
        switch self {
        case .overview, .reports, .repository, .settings: true
        case .pullRequest, .review, .welcome: false
        }
    }
}

/// The main window's tabs, as in an editor: the first tab shows what the sidebar selects (the overview, the
/// reports, a repository, settings); pull requests, reviews and the welcome checklist open in tabs of their own, next to
/// the selected one, and a page already open is selected instead of opened twice.
public struct TabStrip: Equatable, Sendable {
    /// What the browse tab shows.
    public let browse: WorkspacePage
    /// The other tabs, in order.
    public let pages: [WorkspacePage]
    /// The selected tab: `browse` or one of `pages`.
    public let selected: WorkspacePage

    public init(browse: WorkspacePage, pages: [WorkspacePage], selected: WorkspacePage) {
        self.browse = browse
        self.pages = pages
        self.selected = selected
    }

    public static let initial = TabStrip(browse: .overview, pages: [], selected: .overview)

    /// All tabs from left to right.
    public var tabs: [WorkspacePage] { [browse] + pages }

    /// Shows a page: a browse page replaces what the browse tab shows; another page is selected if it is open,
    /// or opened right after the selected tab.
    public func showing(_ page: WorkspacePage) -> TabStrip {
        if page.isBrowsePage {
            return TabStrip(browse: page, pages: pages, selected: page)
        }
        if pages.contains(page) {
            return TabStrip(browse: browse, pages: pages, selected: page)
        }
        let insertAt = pages.firstIndex(of: selected).map { $0 + 1 } ?? pages.count
        var opened = pages
        opened.insert(page, at: insertAt)
        return TabStrip(browse: browse, pages: opened, selected: page)
    }

    /// Selects an open tab; any other page leaves the strip as it is.
    public func selecting(_ page: WorkspacePage) -> TabStrip {
        guard tabs.contains(page) else { return self }
        return TabStrip(browse: browse, pages: pages, selected: page)
    }

    /// Closes a tab. The browse tab stays; closing the selected tab selects its right neighbor, else its left
    /// one, else the browse tab.
    public func closing(_ page: WorkspacePage) -> TabStrip {
        guard let index = pages.firstIndex(of: page) else { return self }
        var remaining = pages
        remaining.remove(at: index)
        guard selected == page else { return TabStrip(browse: browse, pages: remaining, selected: selected) }
        let next = index < remaining.count ? remaining[index] : remaining.last ?? browse
        return TabStrip(browse: browse, pages: remaining, selected: next)
    }

    /// The tab after (or before) the selected one, wrapping around: ⌃Tab and ⌃⇧Tab.
    public func stepping(by offset: Int) -> TabStrip {
        let all = tabs
        guard let index = all.firstIndex(of: selected), !all.isEmpty else { return self }
        let next = ((index + offset) % all.count + all.count) % all.count
        return selecting(all[next])
    }
}
