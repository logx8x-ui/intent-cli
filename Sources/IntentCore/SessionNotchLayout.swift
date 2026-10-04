import Foundation

/// One geometry source for the fixed HUD, previews and display-change recovery.
/// Screen inputs and output frames use AppKit's bottom-left coordinate system.
public struct SessionNotchLayout: Equatable, Sendable {
    public let frame: CGRect
    public let notchWidth: CGFloat
    public let headerHeight: CGFloat
    public let wingWidth: CGFloat
    public let titleHeight: CGFloat = 28
    public let checklistHeight: CGFloat
    public let hasHardwareNotch: Bool

    public init(screen: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
                auxiliaryLeft: CGRect? = nil, auxiliaryRight: CGRect? = nil,
                checklistCount: Int = 0, checklistExpanded: Bool = false) {
        let gap = (auxiliaryRight?.minX ?? 0) - (auxiliaryLeft?.maxX ?? 0)
        let hardware = auxiliaryLeft != nil && auxiliaryRight != nil
            && safeAreaTop > 0 && gap > 0 && gap < screen.width / 2
        hasHardwareNotch = hardware
        notchWidth = hardware ? gap : min(180, screen.width * 0.35)
        headerHeight = hardware ? max(28, safeAreaTop) : 30
        wingWidth = min(112, max(40, (screen.width - notchWidth) / 2))
        let width = notchWidth + wingWidth * 2
        let top = hardware ? screen.maxY : visibleFrame.maxY
        let availableHeight = max(0, top - screen.minY - headerHeight - titleHeight - 16)
        checklistHeight = checklistExpanded && checklistCount > 0
            ? min(252, availableHeight, CGFloat(checklistCount) * 44 + 20) : 0
        let centre = hardware ? (auxiliaryLeft!.maxX + auxiliaryRight!.minX) / 2 : screen.midX
        let height = headerHeight + titleHeight + checklistHeight
        frame = CGRect(x: min(max(centre - width / 2, screen.minX), screen.maxX - width),
                       y: top - height, width: width, height: height)
    }
}
