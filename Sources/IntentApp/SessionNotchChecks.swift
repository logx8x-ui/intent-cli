import AppKit
import SwiftUI
import IntentCore

/// Real panel configuration and real HUD rendering, without ordering a window,
/// starting a session or touching the user's workspace. Live QA is separate.
@MainActor
enum SessionNotchChecks {
    static func run() -> Int32 {
        guard IntentEnvironment.isQA else { return 2 }
        NSApp.setActivationPolicy(.prohibited)
        var count = 0
        func check(_ passed: Bool, _ description: String) throws {
            guard passed else { throw NSError(domain: "SessionNotchChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
            count += 1
        }
        do {
            let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
            let left = CGRect(x: 0, y: 950, width: 656, height: 32)
            let right = CGRect(x: 856, y: 950, width: 656, height: 32)
            let timer = SessionNotchPanel.make()
            try check(!timer.canBecomeKey && !timer.canBecomeMain, "HUD never owns foreground focus")
            try check(!timer.isMovable && !timer.isMovableByWindowBackground && !timer.styleMask.contains(.resizable), "HUD has no dragging or resizing")
            try check(timer.styleMask.contains(.nonactivatingPanel) && !timer.hidesOnDeactivate, "HUD survives working in other apps without activating Intent")
            for mode in IntentionAccessMode.allCases {
                for tasks in [[], ["Review notes", "Finish practice questions", "Write the next step"]] {
                    let layout = SessionNotchLayout(screen: frame, visibleFrame: frame.insetBy(dx: 0, dy: 32), safeAreaTop: 32,
                        auxiliaryLeft: left, auxiliaryRight: right, checklistCount: tasks.count, checklistExpanded: !tasks.isEmpty)
                    let content = SessionNotchContent(title: tasks.isEmpty ? "outlook(2 tabs)-notes" : "Prepare for tomorrow",
                        mode: mode, time: tasks.isEmpty ? "24:59" : nil, timeLabel: "Remaining", checklist: tasks, completed: tasks.isEmpty ? [] : [0], layout: layout)
                    let host = NSHostingView(rootView: content)
                    host.frame = CGRect(origin: .zero, size: layout.frame.size)
                    timer.setFrame(layout.frame, display: false); timer.contentView = host
                    host.layoutSubtreeIfNeeded()
                    try check(timer.frame.maxY == frame.maxY && layout.notchFrame.midX == frame.midX, "HUD respects exact camera anchor, not the asymmetric outer frame centre")
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        throw NSError(domain: "SessionNotchChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "HUD render unavailable"])
                    }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "SessionNotchChecks", code: 3) }
                    try png.write(to: IntentEnvironment.dataDirectory.appendingPathComponent("notch-\(mode.rawValue)-\(tasks.isEmpty ? "timer" : "checklist").png"))
                    try check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "HUD renders in actual AppKit hosting view")
                }
            }
            let completion = SessionCompletionLight.makePanel(frame: frame)
            try check(!completion.canBecomeKey && !completion.canBecomeMain && completion.ignoresMouseEvents, "Completion cannot capture typing or clicks")
            try check(completion.styleMask.contains(.nonactivatingPanel) && !completion.collectionBehavior.contains(.moveToActiveSpace), "Completion cannot activate or move a Space")
            let paths = SessionCompletionLight.paths(size: frame.size, notchLeft: 656, notchRight: 856)
            try check(paths.count == 2 && paths.allSatisfy { $0.currentPoint == CGPoint(x: 756, y: 3) }, "Both light streams meet exactly at the bottom centre")
            try check(paths.allSatisfy { frame.contains($0.boundingBoxOfPath) }, "Completion streams remain on-screen")
            try SessionCompletionLaserChecks.run(check: check)
            let timingFont = NSFont.monospacedDigitSystemFont(ofSize: SessionChromeStyle.timingFontSize, weight: .medium)
            try check(timingFont.pointSize == 13, "Timing uses native menu-bar-sized text, not a large rounded display font")
            for text in ["24:59", "11:59 PM", "01:00:00", "100:00:00"] {
                let width = (text as NSString).size(withAttributes: [.font: timingFont]).width
                try check(width <= SessionChromeStyle.timingContentWidth, "Common clock/countdown \(text) fits at full intended text size")
            }
            for hardware in [true, false] {
                for expanded in [false, true] {
                    let tasks = ["Review a longer checklist item without widening the notch", "한국어 문장 연습", "Send the final draft"]
                    let layout = SessionNotchLayout(screen: frame, visibleFrame: CGRect(x: 0, y: 30, width: 1512, height: 920),
                        safeAreaTop: hardware ? 32 : 0, auxiliaryLeft: hardware ? left : nil, auxiliaryRight: hardware ? right : nil,
                        checklistCount: tasks.count, checklistExpanded: expanded)
                    try check(layout.controlsFrame.maxY <= (hardware ? layout.notchFrame.minY : 950),
                        "Interactive controls never cover the real menu stripe")
                    for slice in [SessionNotchSlice.whole, .header, .controls] {
                        let size = slice == .controls ? layout.controlsCrop.size :
                            CGSize(width: layout.frame.width, height: slice == .header ? layout.headerHeight : layout.frame.height)
                        let content = SessionNotchContent(title: "Prepare tomorrow’s reading — 한국어 and university notes",
                            mode: .whitelist, time: "11:59 PM", timeLabel: "Ends at", checklist: tasks, completed: [0], layout: layout, slice: slice)
                        let host = NSHostingView(rootView: content)
                        host.frame = CGRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
                        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "SessionNotchChecks", code: 7) }
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "SessionNotchChecks", code: 8) }
                        let label = slice == .whole ? "whole" : (slice == .header ? "header" : "controls")
                        try png.write(to: IntentEnvironment.dataDirectory.appendingPathComponent("compact-\(hardware ? "notch" : "external")-\(expanded ? "expanded" : "collapsed")-\(label).png"))
                        try check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "Combined controls and real production crop render without an oversized hidden input region")
                    }
                }
            }
            try checkHostedPanelReplacement(check: check)
            let noticeFrame = SessionFailureNoticePolicy.frame(screen: frame,
                visibleFrame: CGRect(x: 0, y: 30, width: 1512, height: 920), safeAreaTop: 32)
            let notice = SessionFailureNotice.makePanel(frame: noticeFrame, message:
                "The intention stopped because Intent could not safely hide a blocked Chrome window. Window restrictions could not be confirmed, so Intent is releasing this intention and restoring its workspace.")
            try check(!notice.canBecomeKey && !notice.canBecomeMain && notice.ignoresMouseEvents,
                "Failure feedback cannot intercept typing, clicks or become the active main window")
            try check(notice.styleMask.contains(.nonactivatingPanel) && !notice.hidesOnDeactivate
                && !notice.collectionBehavior.contains(.moveToActiveSpace)
                && notice.collectionBehavior.contains(.fullScreenAuxiliary),
                "Failure feedback is nonactivating and can accompany fullscreen work without moving Spaces")
            try check(!notice.isMovable && !notice.isMovableByWindowBackground
                && !notice.styleMask.contains(.resizable) && !notice.isVisible,
                "Notice factory is fixed-layout and never orders a live test window")
            guard let content = notice.contentView else { throw NSError(domain: "SessionNotchChecks", code: 4) }
            content.layoutSubtreeIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw NSError(domain: "SessionNotchChecks", code: 5)
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "SessionNotchChecks", code: 6)
            }
            try png.write(to: IntentEnvironment.dataDirectory.appendingPathComponent("session-failure-notice.png"))
            try check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && notice.frame == noticeFrame,
                "The actual failure notice renders real content at its below-notch frame")
            try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == before, "Isolated checks did not activate Intent")
            timer.close(); completion.close(); notice.close()
            print("Notch presentation checks passed (\(count) assertions; rendered real content, no live UI claim).")
            return 0
        } catch {
            fputs("Notch presentation checks failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    /// Exercise the same NSHostingController replacement used by the running
    /// panels. An NSHostingView bitmap alone misses AppKit's window sizing path.
    private static func checkHostedPanelReplacement(check: (Bool, String) throws -> Void) throws {
        let header = SessionNotchPanel.make()
        let controls = SessionNotchPanel.make()
        defer { header.close(); controls.close() }
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1710, height: 1112)
        let notchWidth: CGFloat = 209, notchHeight: CGFloat = 38
        // NSScreen supplies integral auxiliary-area edges on this hardware.
        // An odd-width camera need not straddle screen.midX symmetrically:
        // inventing a half-point origin exercises NSWindow's point rounding,
        // rather than the hosting replacement regression under test here.
        let notchLeft = (screen.midX - notchWidth / 2).rounded()
        let notchRight = notchLeft + notchWidth
        let left = CGRect(x: screen.minX, y: screen.maxY - notchHeight,
            width: notchLeft - screen.minX, height: notchHeight)
        let right = CGRect(x: notchRight, y: screen.maxY - notchHeight,
            width: screen.maxX - notchRight, height: notchHeight)
        let visible = CGRect(x: screen.minX, y: screen.minY + 30,
            width: screen.width, height: screen.height - 68)
        let tasks = ["First checkpoint", "Second checkpoint"]
        for hardware in [true, false] {
            for expanded in [true, false, true, false] {
                let layout = SessionNotchLayout(screen: screen, visibleFrame: visible,
                    safeAreaTop: hardware ? notchHeight : 0,
                    auxiliaryLeft: hardware ? left : nil, auxiliaryRight: hardware ? right : nil,
                    checklistCount: tasks.count, checklistExpanded: expanded)
                for slice in [SessionNotchSlice.header, .controls] {
                    let panel = slice == .header ? header : controls
                    let expected = slice == .header
                        ? CGRect(x: layout.frame.minX, y: layout.frame.maxY - layout.headerHeight,
                            width: layout.frame.width, height: layout.headerHeight)
                        : layout.controlsFrame
                    let content = SessionNotchContent(title: "Hosting frame regression", mode: .blacklist,
                        time: "01:59", timeLabel: "Remaining", checklist: tasks, completed: [],
                        layout: layout, slice: slice)
                    SessionNotchPanel.setHostedContent(content, in: panel, frame: expected)
                    func geometryDiagnostic() -> String {
                        "hardware=\(hardware), expanded=\(expanded), slice=\(slice), expected=\(expected), "
                            + "frame=\(panel.frame), bounds=\(String(describing: panel.contentView?.bounds))"
                    }
                    try check(panel.contentViewController is NSHostingController<SessionNotchContent>,
                        "Panel placement regression exercises a real hosting controller, not only a bitmap view")
                    try check(panel.frame == expected && panel.contentView?.bounds.size == expected.size,
                        "Content replacement keeps the exact fixed header or checklist frame immediately: \(geometryDiagnostic())")
                    panel.contentView?.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
                    try check(panel.frame == expected && panel.contentView?.bounds.size == expected.size,
                        "Expanded-collapse-expanded hosting/layout cannot move the header above the screen or checklist into the menu stripe: \(geometryDiagnostic())")
                    try check(!panel.isVisible, "Hosting replacement regression never orders a live window")
                }
            }
        }
    }
}
