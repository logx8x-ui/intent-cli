import Foundation

/// A staged Intent editor does not replace the selected desktop window. Only
/// while that editor owns the foreground may outlines use the top visible
/// external window; switching to any other application uses real focus again.
public enum WorkspaceOutlinePresentation {
    public static func windowID(frontmostPID: Int32?, ownPID: Int32, focusedWindowID: UInt32?,
                                topExternalWindowID: UInt32?, preserveBehindIntentPanels: Bool) -> UInt32? {
        if preserveBehindIntentPanels, frontmostPID == ownPID { return topExternalWindowID }
        return focusedWindowID
    }
}
