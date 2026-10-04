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
                    try check(timer.frame.maxY == frame.maxY && timer.frame.midX == frame.midX, "HUD respects exact camera anchor")
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
            for reduced in [false, true] {
                let layer = CALayer()
                SessionCompletionLight.installLayers(on: layer, size: frame.size, notchLeft: 656, notchRight: 856, colour: .systemGreen, reducedMotion: reduced)
                try check(layer.sublayers?.count == (reduced ? 4 : 5), "Reduced motion omits moving sparkle")
                try check(layer.sublayers?.allSatisfy { ($0.animation(forKey: "completion") ?? $0.animation(forKey: "meeting"))?.duration == SessionCompletionLight.duration } == true, "All animation work is finite and shares one completion lifetime")
            }
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
}
