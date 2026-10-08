import Foundation

/// Persist restoration intent with each owned visibility change so finish and
/// crash recovery can restore the workspace without touching user-owned changes.
public enum HiddenWorkspaceRestorationPolicy: String, Codable, Sendable {
    case automatic
    /// Restore all visibility changes still owned by Intent, including entries
    /// left deferred by older versions. User-minimized windows have no entry.
    case restoreOwnedWorkspace
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
        return self == .onUserReveal ? .retain : .reveal
    }

    /// GUI finish restores all Intent-owned changes, including older deferred
    /// entries. Narrow automatic cleanup still only promotes its own entries.
    public func atStop(requested: Self, ownsEntry: Bool) -> Self {
        if requested == .restoreOwnedWorkspace { return .automatic }
        if requested == .onUserReveal { return .onUserReveal }
        return ownsEntry ? .automatic : self
    }

    /// Ordinary deferred windows need no timer/file watch. Parked holders still
    /// need the browser's durable closure receipt before ownership is retired.
    public func needsRecoveryObservation(isParking: Bool) -> Bool {
        self != .onUserReveal || isParking
    }
}
