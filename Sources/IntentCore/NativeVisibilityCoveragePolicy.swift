import Foundation

/// Startup is not ready merely because there are no browser coverage cohorts.
/// The native boundary must supply a complete, live observation after hiding
/// excluded apps/windows. This policy never dispatches effects or restores work.
public struct NativeVisibilityCoveragePolicy {
    public enum ApplicationAction: Equatable {
        case untouched, hideApplication, minimizeWindows(Set<UInt32>)
        public var requiresProcessIdentity: Bool { self != .untouched }
    }
    /// Process identity is required only for a visibility effect we must
    /// verify. An allowed app with no excluded windows may legitimately lack
    /// NSRunningApplication.launchDate (for example Finder at login).
    public static func applicationAction(isCaptureTool: Bool, alwaysAllowed: Bool, explicitlyBlocked: Bool,
                                         applicationExcluded: Bool, excludedWindowIDs: Set<UInt32>) -> ApplicationAction {
        if isCaptureTool || (alwaysAllowed && !explicitlyBlocked) { return .untouched }
        if explicitlyBlocked || applicationExcluded { return .hideApplication }
        return excludedWindowIDs.isEmpty ? .untouched : .minimizeWindows(excludedWindowIDs)
    }
    public struct Target: Hashable {
        public var bundleIdentifier: String
        public var pid: Int32
        public var launched: Double
        /// Nil identifies whole-app hiding, otherwise one exact native window.
        public var windowID: UInt32?
        public init(bundleIdentifier: String, pid: Int32, launched: Double, windowID: UInt32? = nil) {
            self.bundleIdentifier = bundleIdentifier; self.pid = pid
            self.launched = launched; self.windowID = windowID
        }
        public var isValid: Bool {
            !bundleIdentifier.isEmpty && pid > 0 && launched.isFinite && (windowID.map { $0 > 0 } ?? true)
        }
    }
    public enum Outcome: Equatable { case hidden, closed, offscreen, nonUserSurface, permittedAuxiliary, unresolved }
    /// An auxiliary is permitted only through positive type/parent evidence.
    /// A same-app parent does not grant a standard document an exemption.
    public static func permitsAuxiliary(role: String?, subrole: String?, applicationPermitted: Bool,
                                         exactProcessParent: Bool, hasWindowAncestor: Bool,
                                         ancestorBoundToPermittedWindow: Bool, livePermittedNativeWork: Bool,
                                         previouslyStandardWindow: Bool, explicitlyBlockedWindow: Bool = false) -> Bool {
        guard role == "AXWindow", subrole == "AXSystemDialog" || subrole == "AXFloatingWindow",
              applicationPermitted, exactProcessParent, !previouslyStandardWindow, !explicitlyBlockedWindow else { return false }
        return hasWindowAncestor ? ancestorBoundToPermittedWindow : livePermittedNativeWork
    }
    public static let auxiliaryProofLifetime: TimeInterval = 1
    public static func auxiliaryProofIsFresh(observedAt: TimeInterval, now: TimeInterval) -> Bool {
        observedAt.isFinite && now.isFinite && now >= observedAt && now - observedAt <= auxiliaryProofLifetime
    }
    /// CG may retain an untitled, offscreen backing surface which has no AX
    /// user window. Every fact is positive and fresh; omission alone is never
    /// sufficient, and a previously identified user window cannot be waived.
    public static func isNonUserSurface(isUntitled: Bool, serverIdentityStable: Bool, isOnScreen: Bool?,
                                        accessibilityInventoryComplete: Bool, accessibilityGeometryMatch: Bool,
                                        previouslyIdentifiedUserWindow: Bool, allUserWindowsBoundElsewhere: Bool = false) -> Bool {
        isUntitled && serverIdentityStable && isOnScreen == false && accessibilityInventoryComplete
            && !accessibilityGeometryMatch && !previouslyIdentifiedUserWindow && allUserWindowsBoundElsewhere
    }
    public static func allUserWindowsBoundElsewhere(candidates: [Set<UInt32>], excluding target: UInt32) -> Bool {
        candidates.allSatisfy { $0.count == 1 && !$0.contains(target) && !$0.contains(0) }
            && Set(candidates.compactMap(\.first)).count == candidates.count
    }
    public static func serverIdentitiesAreComplete(_ identities: [(pid: Int32, windowID: UInt32)]?) -> Bool {
        guard let identities else { return false }
        return identities.allSatisfy { $0.pid > 0 && $0.windowID > 0 }
            && Set(identities.map(\.windowID)).count == identities.count
    }
    public static func windowFallbackIsCovered(_ outcomes: [Outcome]?, hasUnclassifiedSurfaces: Bool) -> Bool {
        guard let outcomes, !outcomes.isEmpty, !hasUnclassifiedSurfaces else { return false }
        return outcomes.allSatisfy { $0 == .hidden }
    }
    /// Ownership is independent of the overview's minimum preview size.
    /// A small dialog still needs both hiding and exact native restoration.
    public static func usableOwnedWindowGeometry(x: Double, y: Double, width: Double, height: Double) -> Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
    /// NSRunningApplication can disagree with AXHidden for an app whose normal
    /// hide/unhide is rejected. An owned AX effect needs AX readback before its
    /// journal can be released; an unavailable attribute is not a false value.
    public static func applicationHidden(nativeHidden: Bool, accessibilityHidden: Bool?, accessibilityHideOwned: Bool) -> Bool? {
        if nativeHidden { return true }
        if let accessibilityHidden { return accessibilityHidden }
        return accessibilityHideOwned ? nil : false
    }
    public struct Observation {
        public var target: Target
        public var outcome: Outcome
        public init(target: Target, outcome: Outcome) { self.target = target; self.outcome = outcome }
    }
    public enum Reason: String { case inventoryUnavailable, hidingUnconfirmed }
    public struct Failure: Equatable {
        public var reason: Reason
        public var target: Target?
        public var message: String {
            "The intention stopped because Intent could not confirm that excluded apps and windows were hidden. Its workspace is being released safely."
        }
        public init(reason: Reason, target: Target? = nil) { self.reason = reason; self.target = target }
    }
    public static let deadline: TimeInterval = 3
    private let required: Bool
    private var began: TimeInterval?
    private var outcomes: [Target: Outcome] = [:]
    private var stopped = false
    private var failed = false
    public private(set) var initialResolved: Bool
    public var targets: Set<Target> { Set(outcomes.keys) }

    public init(required: Bool) { self.required = required; initialResolved = !required }
    public mutating func begin(now: TimeInterval) {
        guard required, !stopped, began == nil, now.isFinite else { return }
        began = now
    }
    public mutating func stop() { stopped = true }

    /// Nil, malformed or incomplete native observations remain pending. A
    /// missing row does not prove closure; the native boundary must prove it.
    /// Churn cannot extend the single startup deadline or recycle a PID/window.
    public mutating func update(_ observations: [Observation]?, now: TimeInterval) -> Failure? {
        guard required, !initialResolved, !stopped, !failed, now.isFinite else { return nil }
        begin(now: now)
        guard let began else { return nil }
        let inventoryAvailable: Bool
        if let observations, observations.allSatisfy({ $0.target.isValid
            && (($0.outcome != .nonUserSurface && $0.outcome != .permittedAuxiliary && $0.outcome != .offscreen) || $0.target.windowID != nil) }),
           Set(observations.map(\.target)).count == observations.count,
           targets.isSubset(of: Set(observations.map(\.target))) {
            inventoryAvailable = true
            outcomes = Dictionary(uniqueKeysWithValues: observations.map { ($0.target, $0.outcome) })
            if outcomes.values.allSatisfy({ $0 != .unresolved }) {
                initialResolved = true
                return nil
            }
        } else { inventoryAvailable = false }
        guard now - began >= Self.deadline else { return nil }
        failed = true
        return .init(reason: inventoryAvailable ? .hidingUnconfirmed : .inventoryUnavailable,
                     target: inventoryAvailable ? outcomes.first(where: { $0.value == .unresolved })?.key : nil)
    }
}

/// Public AX roots can omit a real window on another Space. Positive native
/// offscreen proof is therefore distinct from hiding, closure or permission.
/// Every admitted exact lifetime stays watched; reappearance or unavailable
/// observations must regain verified hiding within the normal bounded deadline.
/// This never changes the allowed selection or authorizes a foreground click.
public struct NativeOffscreenWindowCoveragePolicy {
    public typealias Target = NativeVisibilityCoveragePolicy.Target
    public typealias Outcome = NativeVisibilityCoveragePolicy.Outcome
    private var tracked: Set<Target> = []
    private var unresolvedSince: [Target: TimeInterval] = [:]
    private var stopped = false
    private var failed = false
    public var targets: Set<Target> { tracked }
    public init() {}
    public mutating func stop() { stopped = true; tracked.removeAll(); unresolvedSince.removeAll() }

    /// Explicit current-policy permission retires only these exact targets.
    /// Missing native observations never call this path and cannot grant access.
    public mutating func retirePermittedTargets(_ targets: Set<Target>) {
        tracked.subtract(targets)
        for target in targets { unresolvedSince.removeValue(forKey: target) }
    }

    public mutating func update(_ observations: [Target: Outcome]?, now: TimeInterval) -> NativeVisibilityCoveragePolicy.Failure? {
        guard !stopped, !failed, now.isFinite else { return nil }
        if let observations {
            tracked.formUnion(observations.compactMap { target, outcome in
                outcome == .offscreen && target.isValid && target.windowID != nil ? target : nil
            })
        }
        for target in tracked {
            switch observations?[target] {
            case .closed?:
                tracked.remove(target); unresolvedSince.removeValue(forKey: target)
            case .hidden?, .offscreen?, .nonUserSurface?, .permittedAuxiliary?:
                unresolvedSince.removeValue(forKey: target)
            case .unresolved?, nil:
                let began = unresolvedSince[target] ?? now
                unresolvedSince[target] = began
                if now - began >= NativeVisibilityCoveragePolicy.deadline {
                    failed = true
                    return .init(reason: observations == nil ? .inventoryUnavailable : .hidingUnconfirmed, target: target)
                }
            }
        }
        return nil
    }
}

/// Shared native app/window effect ordering. A request returning success does
/// not establish visibility: only its live readback can satisfy startup.
public enum NativeVisibilityCoverageEffects {
    /// A rejected native request may still complete asynchronously. Read its
    /// actual state first; journal fallback ownership before the AX request.
    public static func hideWithFallback(isCurrent: () -> Bool, readHidden: () -> Bool?, saveOwnership: () -> Bool,
                                        dispatchPrimary: () -> Void, saveFallbackOwnership: () -> Bool,
                                        dispatchFallback: () -> Void) -> NativeVisibilityCoveragePolicy.Outcome {
        guard isCurrent() else { return .unresolved }
        switch readHidden() {
        case true?: return isCurrent() ? .hidden : .unresolved
        case false?: break
        case nil: return .unresolved
        }
        guard saveOwnership(), isCurrent() else { return .unresolved }
        dispatchPrimary()
        guard isCurrent() else { return .unresolved }
        if readHidden() == true { return isCurrent() ? .hidden : .unresolved }
        guard isCurrent(), saveFallbackOwnership(), isCurrent() else { return .unresolved }
        dispatchFallback()
        guard isCurrent() else { return .unresolved }
        return readHidden() == true && isCurrent() ? .hidden : .unresolved
    }
    /// Returning true retires ownership only after positive visible readback.
    /// The caller supplies exact lifetime checks and nonactivating dispatches.
    public static func restoreWithFallback(isCurrent: () -> Bool, readHidden: () -> Bool?, shouldReveal: () -> Bool,
                                           dispatchPrimary: () -> Void, dispatchFallback: () -> Void) -> Bool {
        guard isCurrent() else { return false }
        let before = readHidden()
        guard isCurrent() else { return false }
        if before == false { return true }
        guard before == true, shouldReveal(), isCurrent() else { return false }
        dispatchPrimary()
        guard isCurrent() else { return false }
        if readHidden() == false { return isCurrent() }
        guard isCurrent() else { return false }
        dispatchFallback()
        guard isCurrent() else { return false }
        return readHidden() == false && isCurrent()
    }
    public static func hide(isCurrent: () -> Bool, readHidden: () -> Bool?,
                            saveOwnership: () -> Bool, dispatch: () -> Bool) -> NativeVisibilityCoveragePolicy.Outcome {
        guard isCurrent() else { return .unresolved }
        switch readHidden() {
        case true?: return isCurrent() ? .hidden : .unresolved // User-owned hidden state stays unowned.
        case false?: break
        case nil: return .unresolved
        }
        guard saveOwnership(), isCurrent(), dispatch(), isCurrent() else { return .unresolved }
        return readHidden() == true ? .hidden : .unresolved
    }
}
