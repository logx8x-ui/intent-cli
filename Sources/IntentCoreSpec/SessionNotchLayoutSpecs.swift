import Foundation
import IntentCore

func runSessionNotchLayoutSpecs() throws {
    let deadline = Date(timeIntervalSince1970: 1_000)
    try expect(SessionTimerFormatter.showsAbsoluteEnd(deadline, effectiveEnd: deadline), "End-time-only HUD displays its chosen clock time")
    try expect(!SessionTimerFormatter.showsAbsoluteEnd(deadline, effectiveEnd: deadline.addingTimeInterval(-60)), "Combined modifiers display the earlier timer rather than a misleading later end time")
    try expect(!SessionTimerFormatter.showsAbsoluteEnd(nil, effectiveEnd: deadline), "Duration timer uses countdown")
    for origin in [CGPoint.zero, CGPoint(x: -1512, y: -300), CGPoint(x: 900, y: 982)] {
        let screen = CGRect(origin: origin, size: CGSize(width: 1512, height: 982))
        let visible = CGRect(x: screen.minX, y: screen.minY + 70, width: screen.width, height: screen.height - 102)
        let left = CGRect(x: screen.minX, y: screen.maxY - 32, width: 656, height: 32)
        let right = CGRect(x: screen.minX + 856, y: screen.maxY - 32, width: 656, height: 32)
        let timer = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 32, auxiliaryLeft: left, auxiliaryRight: right)
        try expect(timer.hasHardwareNotch && timer.notchWidth == 200, "HUD uses the camera exclusion, never a guessed MacBook notch width")
        try expect(timer.frame.maxY == visible.maxY - 6 && timer.frame.midX == timer.notchFrame.midX,
            "Capsule centres below the physical camera on offset displays")
        try expect(timer.headerHeight == 28 && timer.frame.height == 28 && timer.frame.width == 264,
            "The silver capsule is one compact 28-point row without wings or a name lip")
        try expect(timer.notchFrame.minX == left.maxX && timer.notchFrame.maxX == right.minX,
            "Actual camera exclusion remains independently measured")
        try expect(timer.controlsFrame == timer.frame && timer.controlsFrame.maxY < timer.notchFrame.minY,
            "Collapsed capsule interaction stays entirely below the camera and menu stripe")
        let checklist = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 32, auxiliaryLeft: left, auxiliaryRight: right, checklistCount: 100, checklistExpanded: true)
        try expect(checklist.frame.maxY == timer.frame.maxY && checklist.frame.midX == timer.frame.midX, "Checklist expansion never moves the notch anchor")
        try expect(checklist.checklistHeight == 204 && screen.contains(checklist.frame), "Long lists scroll within a compact screen-safe tray")
        try expect(checklist.controlsFrame.maxY == timer.frame.maxY && checklist.controlsFrame.maxY < timer.notchFrame.minY,
            "Expanded controls cannot intercept menu clicks or register a menu-stripe input exclusion")
        let collapsed = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 32, auxiliaryLeft: left, auxiliaryRight: right, checklistCount: 5)
        try expect(collapsed == timer, "Collapsed checklist retains exact timer geometry")
        let oddCamera = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 32,
            auxiliaryLeft: left, auxiliaryRight: CGRect(x: right.minX + 9, y: right.minY, width: right.width - 9, height: right.height))
        try expect(oddCamera.frame.minX.rounded() == oddCamera.frame.minX
            && abs(oddCamera.frame.midX - oddCamera.notchFrame.midX) <= 0.5,
            "Odd-width cameras use a whole-point panel origin without AppKit moving the hosted content")
        let fallback = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 0)
        try expect(!fallback.hasHardwareNotch && fallback.frame.maxY == visible.maxY - 6, "External displays use the same capsule below the menu bar")
        try expect(screen.contains(fallback.frame), "Fallback remains on its selected screen")
        try expect(fallback.frame.width == 264 && fallback.frame.height == 28 && fallback.titleHeight == 0,
            "No-notch displays use the same compact named row without a fake camera cutout")
        try expect(fallback.controlsFrame == fallback.frame && fallback.frame.maxY <= visible.maxY,
            "Fallback interaction is wholly below the real menu bar")
        let stale = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 32)
        try expect(!stale.hasHardwareNotch, "Missing camera areas use safe fallback rather than inventing camera geometry")
        for areas in [(Optional(left), Optional<CGRect>.none), (nil, Optional(right))] {
            let partial = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 32, auxiliaryLeft: areas.0, auxiliaryRight: areas.1)
            try expect(!partial.hasHardwareNotch, "Either missing camera side safely falls back without unwrapping incomplete display metadata")
        }
    }
    print("Notch layout regressions passed (notch, external display, offsets, checklist bounds).")
}
