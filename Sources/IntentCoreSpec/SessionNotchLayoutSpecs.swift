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
        try expect(timer.frame.maxY == screen.maxY && timer.frame.midX == screen.midX, "HUD surrounds the physical notch on offset displays")
        try expect(timer.headerHeight == 32 && timer.frame.height == 60, "Timer has one fixed size, including name below the camera")
        let checklist = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 32, auxiliaryLeft: left, auxiliaryRight: right, checklistCount: 100, checklistExpanded: true)
        try expect(checklist.frame.maxY == timer.frame.maxY && checklist.frame.midX == timer.frame.midX, "Checklist expansion never moves the notch anchor")
        try expect(checklist.checklistHeight == 252 && screen.contains(checklist.frame), "Long lists scroll within a bounded screen-safe tray")
        let collapsed = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 32, auxiliaryLeft: left, auxiliaryRight: right, checklistCount: 5)
        try expect(collapsed == timer, "Collapsed checklist retains exact timer geometry")
        let fallback = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 0)
        try expect(!fallback.hasHardwareNotch && fallback.frame.maxY == visible.maxY, "External displays use a fixed top-centre cap below the menu bar")
        try expect(screen.contains(fallback.frame), "Fallback remains on its selected screen")
        let stale = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 32)
        try expect(!stale.hasHardwareNotch, "Missing camera areas use safe fallback rather than inventing camera geometry")
        for areas in [(Optional(left), Optional<CGRect>.none), (nil, Optional(right))] {
            let partial = SessionNotchLayout(screen: screen, visibleFrame: visible, safeAreaTop: 32, auxiliaryLeft: areas.0, auxiliaryRight: areas.1)
            try expect(!partial.hasHardwareNotch, "Either missing camera side safely falls back without unwrapping incomplete display metadata")
        }
    }
    print("Notch layout regressions passed (notch, external display, offsets, checklist bounds).")
}
