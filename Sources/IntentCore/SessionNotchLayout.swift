import Foundation

/// One geometry source for the fixed HUD, previews and display-change recovery.
/// Screen inputs and output frames use AppKit's bottom-left coordinate system.
public struct SessionNotchLayout: Equatable, Sendable {
    public let frame: CGRect
    public let notchFrame: CGRect
    public let notchWidth: CGFloat
    public let headerHeight: CGFloat
    public let leadingWingWidth: CGFloat
    public let trailingWingWidth: CGFloat
    public let titleHeight: CGFloat
    public let checklistHeight: CGFloat
    public let hasHardwareNotch: Bool
    /// Top-left view coordinates. Only this region may receive checklist input.
    public var controlsCrop: CGRect {
        CGRect(origin: .zero, size: frame.size)
    }
    public var controlsFrame: CGRect {
        let crop = controlsCrop
        return CGRect(x: frame.minX + crop.minX, y: frame.maxY - crop.maxY,
            width: crop.width, height: crop.height)
    }

    public init(screen: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
                auxiliaryLeft: CGRect? = nil, auxiliaryRight: CGRect? = nil,
                checklistCount: Int = 0, checklistExpanded: Bool = false) {
        let gap = (auxiliaryRight?.minX ?? 0) - (auxiliaryLeft?.maxX ?? 0)
        let hardware = auxiliaryLeft != nil && auxiliaryRight != nil
            && safeAreaTop > 0 && safeAreaTop < screen.height / 2
            && gap > 0 && gap < screen.width / 2
            && auxiliaryLeft!.maxX >= screen.minX && auxiliaryRight!.minX <= screen.maxX
        hasHardwareNotch = hardware
        notchWidth = hardware ? gap : min(128, screen.width * 0.5)
        headerHeight = 28
        titleHeight = 0
        let centre = hardware ? (auxiliaryLeft!.maxX + auxiliaryRight!.minX) / 2 : screen.midX
        leadingWingWidth = 24
        trailingWingWidth = 76
        let width = min(264, max(0, screen.width - 24))
        // The capsule is wholly below both camera and menu bar. Its input
        // region never touches either, including on offset/external displays.
        let top = min(visibleFrame.maxY, hardware ? screen.maxY - safeAreaTop : visibleFrame.maxY) - 6
        let availableHeight = max(0, top - visibleFrame.minY - headerHeight - titleHeight - 12)
        checklistHeight = checklistExpanded && checklistCount > 0
            ? min(204, availableHeight, CGFloat(checklistCount) * 34 + 12) : 0
        let height = headerHeight + titleHeight + checklistHeight
        // AppKit rounds window origins to whole points. Match it up front so
        // an odd-width camera cannot shift the hosted crop after assignment.
        frame = CGRect(x: min(screen.maxX - width - 12, max(screen.minX + 12, centre - width / 2)).rounded(.down),
                       y: top - height, width: width, height: height)
        notchFrame = CGRect(x: centre - notchWidth / 2, y: screen.maxY - (hardware ? safeAreaTop : 0),
            width: notchWidth, height: hardware ? safeAreaTop : 0)
    }
}
