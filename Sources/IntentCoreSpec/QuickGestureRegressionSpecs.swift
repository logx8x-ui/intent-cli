import Foundation
import IntentCore

func runQuickGestureRegressionSpecs() throws {
    // Repeated clean/reused input sequences with a deterministic event clock.
    for iteration in 0..<100 {
        let base = Double(iteration) * 3
        var gesture = QuickMarkGesture()
        _ = gesture.key(code: 50, down: true, modified: false, repeatKey: false, now: base)
        for n in 1...5 {
            try expect(gesture.key(code: 50, down: true, modified: false, repeatKey: true, now: base + Double(n) / 100).action == nil, "Held backtick never repeats an action")
        }
        _ = gesture.key(code: 50, down: false, modified: false, repeatKey: false, now: base + 0.06)
        try expect(gesture.expire(now: base + 0.339) == nil, "Single waits across the double-tap threshold")
        try expect(gesture.key(code: 50, down: true, modified: false, repeatKey: false, now: base + 0.339).action == .mark, "Near-threshold double wins without a single action")
        _ = gesture.key(code: 50, down: false, modified: false, repeatKey: false, now: base + 0.36)
        try expect(gesture.expire(now: base + 1) == nil, "Confirmed double cannot also collapse/open UI")
        _ = gesture.key(code: 50, down: true, modified: false, repeatKey: false, now: base + 1.1)
        _ = gesture.key(code: 50, down: false, modified: false, repeatKey: false, now: base + 1.15)
        gesture.reset() // Session changes and text-entry context invalidate pending input.
        try expect(gesture.expire(now: base + 2) == nil, "Session transition cancels stale pending gesture")
    }
    var gesture = QuickMarkGesture()
    _ = gesture.key(code: 50, down: true, modified: false, repeatKey: false, now: 0)
    _ = gesture.key(code: 50, down: false, modified: false, repeatKey: false, now: 0.02)
    _ = gesture.key(code: 0, down: true, modified: false, repeatKey: false, now: 0.04)
    try expect(gesture.expire(now: 1) == nil, "Continuing to type cancels single gesture")
    for code in [18, 19, 20, 21, 11, 48, 36, 53] {
        gesture.reset()
        _ = gesture.key(code: 50, down: true, modified: false, repeatKey: false, now: 0)
        try expect(!gesture.key(code: code, down: true, modified: true, repeatKey: false, now: 0.01).consume, "Modified keys are never treated as plain backtick chords")
    }
    gesture.reset()
    _ = gesture.key(code: 50, down: true, modified: false, repeatKey: false, now: 0)
    _ = gesture.key(code: 50, down: true, modified: true, repeatKey: true, now: 0.1)
    _ = gesture.key(code: 50, down: false, modified: true, repeatKey: false, now: 0.2)
    try expect(gesture.expire(now: 1) == nil, "Changing modifiers during a held gesture cannot fire a stale single")
    gesture.reset()
    _ = gesture.key(code: 50, down: true, modified: false, repeatKey: false, now: 0)
    _ = gesture.key(code: 18, down: true, modified: false, repeatKey: false, now: 0.1)
    _ = gesture.key(code: 19, down: true, modified: false, repeatKey: false, now: 0.2)
    try expect(gesture.key(code: 19, down: false, modified: false, repeatKey: false, now: 0.3).consume, "Suppressed extra chord keys consume their matching release")
    gesture.reset()
    _ = gesture.key(code: 50, down: true, modified: false, repeatKey: false, now: 0)
    _ = gesture.key(code: 50, down: false, modified: false, repeatKey: false, now: 0.02)
    try expect(gesture.key(code: 50, down: true, modified: false, repeatKey: false, now: 0.31).action == .single, "A delayed expiry callback cannot lose the first completed single")
    _ = gesture.key(code: 50, down: false, modified: false, repeatKey: false, now: 0.35)
    try expect(gesture.expire(now: 0.64) == .single, "Two taps outside the double interval remain two distinct singles")
    var rules = ActiveBrowserRules(active: true, allowedWebsites: [], selectedTabIDsByBrowser: ["com.google.Chrome": [1]], selectedBrowserSessionIDsByBrowser: ["com.google.Chrome": "session-a"], blockTabSwitching: true, blockNavigation: true, blockNewTabs: true)
    let snapshot = BrowserTabSnapshot(browserBundleIdentifier: "com.google.Chrome", browserSessionID: "session-a", tabs: [])
    try expect(rules.matchesBrowserSession(snapshot), "Native guards accept matching browser epoch")
    var restarted = snapshot; restarted.browserSessionID = "session-b"
    try expect(!rules.matchesBrowserSession(restarted), "Native guards never mask a recycled tab identity after browser restart")
    restarted.browserSessionID = nil
    try expect(!rules.matchesBrowserSession(restarted), "Missing browser epoch cannot authorize exact tab masks")
    rules.selectedTabIDsByBrowser = nil
    try expect(rules.matchesBrowserSession(restarted), "Saved URL-based rules do not require transient tab identities")
    print("Quick gesture regressions passed (100 repeated sequences)")
}
