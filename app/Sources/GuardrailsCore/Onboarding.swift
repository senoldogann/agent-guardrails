import Foundation

/// A first-run step and whether this Mac has done it.
public struct OnboardingStep: Sendable, Equatable, Identifiable {
    public enum ID: String, Sendable, CaseIterable {
        case kit
        case github
        case notifications
        case agentApp
        case firstRepo
    }

    public enum State: Sendable, Equatable {
        case done
        case todo
        /// Not known yet (still loading).
        case checking
    }

    public let id: ID
    public let state: State
    /// The agent App is recommended, not required: without it the kit works in status mode.
    public let isOptional: Bool
}

/// What the app knows about this Mac; nil while still loading.
public struct OnboardingFacts: Sendable, Equatable {
    public let kitFound: Bool
    public let githubSignedIn: Bool?
    public let notificationsShown: Bool?
    public let agentRegistered: Bool?
    public let enforcedRepos: Int?

    public init(kitFound: Bool, githubSignedIn: Bool?, notificationsShown: Bool?, agentRegistered: Bool?, enforcedRepos: Int?) {
        self.kitFound = kitFound
        self.githubSignedIn = githubSignedIn
        self.notificationsShown = notificationsShown
        self.agentRegistered = agentRegistered
        self.enforcedRepos = enforcedRepos
    }
}

/// The first-run checklist in the order the owner works through it.
public func onboardingSteps(_ facts: OnboardingFacts) -> [OnboardingStep] {
    func state(_ known: Bool?) -> OnboardingStep.State {
        known.map { $0 ? .done : .todo } ?? .checking
    }
    return [
        OnboardingStep(id: .kit, state: facts.kitFound ? .done : .todo, isOptional: false),
        OnboardingStep(id: .github, state: state(facts.githubSignedIn), isOptional: false),
        OnboardingStep(id: .notifications, state: state(facts.notificationsShown), isOptional: false),
        OnboardingStep(id: .agentApp, state: state(facts.agentRegistered), isOptional: true),
        OnboardingStep(id: .firstRepo, state: state(facts.enforcedRepos.map { $0 > 0 }), isOptional: false),
    ]
}

/// Every required step is done; the optional agent App may still be missing.
public func onboardingIsComplete(_ steps: [OnboardingStep]) -> Bool {
    steps.allSatisfy { $0.isOptional || $0.state == .done }
}
