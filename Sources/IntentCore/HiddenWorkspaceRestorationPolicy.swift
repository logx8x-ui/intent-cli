import Foundation

/// Persist quiet completion with each owned visibility change before hiding it so a
/// retry, app restart, or subsequent session cannot silently reveal it later.
public enum HiddenWorkspaceRestorationPolicy: String, Codable, Sendable {
    case automatic
    case onUserReveal

    public enum Action: Equatable {
        case reveal
        case retain
        case relinquish
    }

    public enum DeferredVisibilityResolution: Equatable {
        /// Satisfies the new session's hidden-window coverage without claiming
        /// an effect that the new controller did not perform.
        case alreadyHidden
        /// The user revealed the old window. Durably retire its old entry before
        /// any new controller saves ownership and hides it again.
        case retireForCurrentOwnership
        case unresolved
    }

    public func historicalDeferredVisibility(isHidden: Bool?) -> DeferredVisibilityResolution {
        guard self == .onUserReveal, let isHidden else { return .unresolved }
        return isHidden ? .alreadyHidden : .retireForCurrentOwnership
    }

    public func action(isHidden: Bool?) -> Action {
        guard let isHidden else { return .retain }
        if !isHidden { return .relinquish }
        return self == .automatic ? .reveal : .retain
    }

    /// A successful GUI finish cannot reveal even an older pending entry.
    /// Explicit safety/failed-start cleanup restores only this controller's
    /// changes, never a previous intention's deliberately deferred workspace.
    public func atStop(requested: Self, ownsEntry: Bool) -> Self {
        if requested == .onUserReveal { return .onUserReveal }
        return ownsEntry ? .automatic : self
    }

    /// Ordinary deferred windows need no timer/file watch. Parked holders still
    /// need the browser's durable closure receipt before ownership is retired.
    public func needsRecoveryObservation(isParking: Bool) -> Bool {
        self == .automatic || isParking
    }
}
