import Foundation

/// Recovery may undo only its own focus changes, never a user's next action.
public struct RestorationFocusPolicy {
    public static func inputChanged(initial: [UInt32], current: [UInt32]) -> Bool {
        // Equality, not a positive delta: WindowServer counters may wrap.
        initial != current
    }
    /// Finishing from Intent's controls must preserve the work underneath them,
    /// rather than a transient panel that is about to close.
    public static func targetPID(frontmostPID: Int32?, controllerPID: Int32, visiblePID: Int32?) -> Int32? {
        guard let frontmostPID else { return nil }
        if frontmostPID != controllerPID { return frontmostPID }
        guard let visiblePID, visiblePID != controllerPID else { return nil }
        return visiblePID
    }

    private let originalPID: Int32
    private let restoringPIDs: Set<Int32>
    private var cancelled = false
    public init(originalPID: Int32, restoringPIDs: Set<Int32>) {
        self.originalPID = originalPID
        self.restoringPIDs = restoringPIDs
    }
    public mutating func userInteracted() { cancelled = true }
    public mutating func shouldPreserve(frontmostPID: Int32?) -> Bool {
        guard !cancelled, let frontmostPID else { return false }
        guard frontmostPID == originalPID || restoringPIDs.contains(frontmostPID) else {
            cancelled = true
            return false
        }
        return true
    }

    /// A native owner may queue preservation immediately after its own restore,
    /// without waiting for an AX read that the restoring browser may not answer.
    /// Positive native visibility is required: never chase a target to a Space
    /// or undo a user's minimization merely because its process still exists.
    public mutating func shouldPreserveOwnedVisibilityChange(targetExists: Bool?, targetOnScreen: Bool,
                                                             frontmostPID: Int32?) -> Bool {
        let permitted = shouldPreserve(frontmostPID: frontmostPID)
        return permitted && targetExists == true && targetOnScreen
    }
}
