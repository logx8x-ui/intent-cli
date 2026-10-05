import Foundation
import IntentCore

func runQuickGestureRegressionSpecs() throws {
    try runQuickMarkKeyboardInputSpecs()
    var finder = OverviewSearchGesture()
    try expect(!finder.key(code: 17, down: true, modified: false, repeated: false, editing: false).consume,
        "T without a browser picker is ordinary input")
    try expect(!finder.key(code: 17, down: true, modified: false, repeated: false, editing: true, browserPickerAvailable: true).consume,
        "Typing T in a name, modifier or search never reopens the finder")
    try expect(finder.key(code: 17, down: true, modified: false, repeated: false, editing: false, browserPickerAvailable: true).action == .websiteFinder,
        "T in the chosen browser picker opens the finder")
    try expect(finder.key(code: 17, down: true, modified: false, repeated: true, editing: true, browserPickerAvailable: true).action == nil,
        "Holding T cannot repeatedly create finders")
    try expect(finder.key(code: 17, down: false, modified: true, repeated: false, editing: true).consume,
        "Finder trigger owns its release even after focus and modifier changes")
    for editing in [false, true] {
        var close = OverviewSearchGesture()
        _ = close.key(code: 50, down: true, modified: false, repeated: false, editing: editing)
        try expect(close.key(code: 50, down: false, modified: false, repeated: false, editing: editing).action == .close,
            "Plain backtick exits overview including an open editor")
    }
    for capsFirst in [true, false] {
        var run = QuickMarkGesture()
        let first = run.key(code: 50, down: true, modified: false, repeatKey: false, now: 0, capsLockHeld: capsFirst)
        let result = capsFirst ? first : run.key(code: 57, down: true, modified: false, repeatKey: false, now: 0.02)
        try expect(result.action == .run, "Caps Lock and backtick start in either order")
        try expect(run.key(code: 57, down: true, modified: false, repeatKey: true, now: 0.03).action == nil, "Run chord cannot repeat")
        _ = run.key(code: 50, down: false, modified: false, repeatKey: false, now: 0.05)
        try expect(run.expire(now: 1) == nil, "Run never opens the picker on release")
    }
    var configured = QuickMarkGesture()
    _ = configured.key(code: 50, down: true, modified: false, repeatKey: false, now: 0)
    _ = configured.key(code: 18, down: true, modified: false, repeatKey: false, now: 0.1)
    _ = configured.key(code: 18, down: false, modified: false, repeatKey: false, now: 0.2)
    try expect(configured.key(code: 57, down: true, modified: false, repeatKey: false, now: 0.3).action == .run, "Caps Lock can start after modifier changes without releasing backtick")
    var retired = QuickMarkGesture()
    _ = retired.key(code: 50, down: true, modified: false, repeatKey: false, now: 0)
    try expect(retired.key(code: 36, down: true, modified: false, repeatKey: false, now: 0.02).action == nil, "Retired backtick Return cannot start a session")
    var capitals = QuickMarkGesture()
    try expect(capitals.key(code: 50, down: true, modified: false, repeatKey: false, now: 0, capsLockHeld: false).action == nil, "Latched capitals are not a physically held Caps Lock key")
    try expect(SessionModificationOrder.migrated(stored: ["Searches", "Timer"], available: ["Timer", "Tab searches"]) == ["Tab searches", "Timer"], "Renaming preserves the user's shortcut ordering")
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
    for (n, code) in [18, 19, 20, 21, 18].enumerated() {
        let time = 0.1 + Double(n) * 0.1
        try expect(gesture.key(code: code, down: true, modified: false, repeatKey: false, now: time).action == .modification([18,19,20,21].firstIndex(of: code)!), "One backtick hold supports all modifier numbers and toggling the same one again")
        try expect(gesture.key(code: code, down: true, modified: false, repeatKey: true, now: time + 0.01).action == nil, "A held number cannot repeatedly toggle a modifier")
        try expect(gesture.key(code: code, down: false, modified: false, repeatKey: false, now: time + 0.02).consume, "Each chord release is consumed")
    }
    _ = gesture.key(code: 50, down: false, modified: false, repeatKey: false, now: 0.7)
    try expect(gesture.expire(now: 1) == nil, "A multi-modifier hold cannot open overview on release")
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
