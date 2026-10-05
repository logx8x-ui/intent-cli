import Foundation

/// The browserless native cohort uses the same durable ownership as reported
/// normal windows. Keep the effect ordering testable without touching real apps.
public enum BrowserWindowCoverageEffects {
    public struct Ownership: Equatable {
        public var native: BrowserWindowCoveragePolicy.NativeIdentity
        public var intentionSessionID: String
        public var browserSessionID: String?
        public var browserWindowID: Int?
        public var isNativeCoverage: Bool
        public init(native: BrowserWindowCoveragePolicy.NativeIdentity, intentionSessionID: String,
                    browserSessionID: String? = nil, browserWindowID: Int? = nil, isNativeCoverage: Bool = true) {
            self.native = native; self.intentionSessionID = intentionSessionID
            self.browserSessionID = browserSessionID; self.browserWindowID = browserWindowID
            self.isNativeCoverage = isNativeCoverage
        }
    }

    public static func minimize(isCurrent: () -> Bool, readMinimized: () -> Bool?,
                                saveOwnership: () -> Bool, dispatch: () -> Void) -> BrowserWindowCoverageCohort.Outcome {
        guard isCurrent() else { return .unresolved }
        // Pre-minimized windows can satisfy coverage but never become owned.
        switch readMinimized() {
        case true?: return .minimized
        case false?: break
        case nil: return .unresolved
        }
        guard saveOwnership(), isCurrent() else { return .unresolved }
        dispatch()
        return readMinimized() == true ? .minimized : .unresolved
    }

    /// Readback, not dispatch success, retires ownership. A second recovery pass
    /// observes an already-restored window without dispatching another effect.
    public static func mayRestore(ownershipSessionID: String?, activeSessionID: String?) -> Bool {
        activeSessionID == nil || activeSessionID == ownershipSessionID
    }
    public static func restore(ownershipSessionID: String? = nil, activeSessionID: String? = nil,
                               readMinimized: () -> Bool?, dispatch: () -> Void) -> Bool {
        guard mayRestore(ownershipSessionID: ownershipSessionID, activeSessionID: activeSessionID) else { return false }
        switch readMinimized() {
        case false?: return true
        case true?: break
        case nil: return false
        }
        dispatch()
        return readMinimized() == false
    }

    /// Replace the same journal entry, rather than appending a second owner.
    /// Fresh claim/active-rule checks remain at the native boundary.
    public static func transfer(_ ownership: Ownership, native: BrowserWindowCoveragePolicy.NativeIdentity,
                                intentionSessionID: String, browserSessionID: String, browserWindowID: Int,
                                isCurrent: () -> Bool, persist: (Ownership) -> Bool) -> Bool {
        guard native.isValid, native == ownership.native, ownership.isNativeCoverage,
              !intentionSessionID.isEmpty, ownership.intentionSessionID == intentionSessionID,
              !browserSessionID.isEmpty, browserWindowID >= 0, isCurrent() else { return false }
        var updated = ownership
        updated.browserSessionID = browserSessionID; updated.browserWindowID = browserWindowID
        updated.isNativeCoverage = false
        return persist(updated)
    }
}
