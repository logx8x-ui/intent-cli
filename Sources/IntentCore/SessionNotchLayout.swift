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
        guard hasHardwareNotch else { return CGRect(origin: .zero, size: frame.size) }
        return CGRect(x: checklistHeight > 0 ? 0 : leadingWingWidth, y: headerHeight,
            width: checklistHeight > 0 ? frame.width : notchWidth,
            height: titleHeight + checklistHeight)
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
        headerHeight = hardware ? safeAreaTop : 24
        titleHeight = hardware ? 14 : 0
        let centre = hardware ? (auxiliaryLeft!.maxX + auxiliaryRight!.minX) / 2 : screen.midX
        leadingWingWidth = min(24, max(0, centre - notchWidth / 2 - screen.minX))
        trailingWingWidth = min(76, max(0, screen.maxX - centre - notchWidth / 2))
        let width = notchWidth + leadingWingWidth + trailingWingWidth
        let top = hardware ? screen.maxY : visibleFrame.maxY
        let availableHeight = max(0, top - visibleFrame.minY - headerHeight - titleHeight - 12)
        checklistHeight = checklistExpanded && checklistCount > 0
            ? min(204, availableHeight, CGFloat(checklistCount) * 34 + 12) : 0
        let height = headerHeight + titleHeight + checklistHeight
        frame = CGRect(x: hardware ? centre - notchWidth / 2 - leadingWingWidth : centre - width / 2,
                       y: top - height, width: width, height: height)
        notchFrame = CGRect(x: frame.minX + leadingWingWidth, y: top - headerHeight,
            width: notchWidth, height: headerHeight)
    }
}
