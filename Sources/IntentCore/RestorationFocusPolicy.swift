import Foundation

/// Recovery may undo only its own focus changes, never a user's next action.
public struct RestorationFocusPolicy {
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
}
