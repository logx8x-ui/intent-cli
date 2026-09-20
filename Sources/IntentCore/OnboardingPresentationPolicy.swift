import Foundation

/// A presentation request raises the existing coach without changing tutorial
/// progress. Merely updating its content must never take keyboard focus.
public struct OnboardingPresentationPolicy {
    public enum Action: Equatable { case none, hide, show, showAndFocus }
    private var lastRequest: UUID?
    private var pendingFocus = false
    private var hasShown = false
    private var wasCovered = false

    public init() {}

    public mutating func update(isPresented: Bool, selectionVisible: Bool,
                                request: UUID?, initialEntryFocus: Bool,
                                permissionHandoffActive: Bool = false) -> Action {
        if request != lastRequest {
            lastRequest = request
            pendingFocus = request != nil
        }
        let covered = selectionVisible || permissionHandoffActive
        let returningFromCover = wasCovered && !covered
        wasCovered = covered
        guard isPresented else {
            pendingFocus = false
            hasShown = false
            return .hide
        }
        guard !covered else { return .hide }
        if pendingFocus {
            pendingFocus = false
            hasShown = true
            return .showAndFocus
        }
        if !hasShown {
            hasShown = true
            return initialEntryFocus ? .showAndFocus : .show
        }
        return returningFromCover ? .show : .none
    }
}

/// Permission setup includes Settings and its authentication sheets. Do not
/// bring the coach back over those sheets just because another process activates.
public struct OnboardingPermissionHandoffPolicy {
    public private(set) var isSuspended = false
    private var settingsObserved = false

    public init() {}
    public mutating func begin() { isSuspended = true; settingsObserved = false }
    public mutating func resume() { isSuspended = false; settingsObserved = false }

    public mutating func activatedApplication(_ bundleIdentifier: String?, intentBundleIdentifier: String?) {
        if bundleIdentifier == "com.apple.systempreferences" {
            isSuspended = true
            settingsObserved = true
        } else if settingsObserved, let intentBundleIdentifier, bundleIdentifier == intentBundleIdentifier {
            resume()
        }
    }
}
