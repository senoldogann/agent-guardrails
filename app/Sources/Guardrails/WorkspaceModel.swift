import Foundation
import GuardrailsCore
import Observation

/// One run of a guardrails action shown in a tab: the CLI session and what the Review page reads from GitHub.
/// It lives as long as its tab, so switching tabs keeps a running approval and its loaded checks.
@MainActor
@Observable
final class ReviewSession {
    let request: ActionRequest
    let action: ActionModel
    let evidence = PullRequestEvidence()

    init(request: ActionRequest, action: ActionModel) {
        self.request = request
        self.action = action
    }
}

/// The main window's tabs and the models of the pages open in them.
@MainActor
@Observable
final class Workspace {
    private(set) var strip = TabStrip.initial
    private(set) var reviews: [UUID: ReviewSession] = [:]
    private(set) var pullRequests: [PullRequestRef: PullRequestModel] = [:]

    func show(_ page: WorkspacePage) {
        strip = strip.showing(page)
    }

    func select(_ page: WorkspacePage) {
        strip = strip.selecting(page)
    }

    func step(by offset: Int) {
        strip = strip.stepping(by: offset)
    }

    func showPullRequest(_ ref: PullRequestRef) {
        if pullRequests[ref] == nil { pullRequests[ref] = PullRequestModel(ref: ref) }
        show(.pullRequest(ref))
    }

    /// Starts the action's run and shows it. The run goes on if its tab closes after the final confirmation.
    func showReview(_ request: ActionRequest, configuration: AppConfiguration, onFinish: @escaping @MainActor @Sendable (ActionModel) -> Void) {
        let action = ActionModel(request: request, configuration: configuration)
        reviews[request.run] = ReviewSession(request: request, action: action)
        action.start(onFinish: onFinish)
        show(.review(request.run))
    }

    /// Closes a tab. A review that still waits for the owner is cancelled; after the final confirmation the
    /// CLI keeps running and its outcome is still logged.
    func close(_ page: WorkspacePage) {
        switch page {
        case .review(let run):
            reviews[run]?.action.cancel()
            reviews[run] = nil
        case .pullRequest(let ref):
            pullRequests[ref] = nil
        case .overview, .repository, .settings, .welcome:
            break
        }
        strip = strip.closing(page)
    }

    /// Closes the selected tab, or reports that the browse tab is selected (it cannot close).
    func closeSelected() -> Bool {
        guard !strip.selected.isBrowsePage else { return false }
        close(strip.selected)
        return true
    }
}
