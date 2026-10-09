import Foundation
import IntentCore
import IntentLock

func runWorkspaceTabOutlineSpecs() throws {
    try runWorkspaceOutlineInventorySpecs()
    struct Node {
        var attributes: [String: String]
        var children: [Int] = []
        var frame: CGRect? = nil
        init(_ role: String, children: [Int] = [], frame: CGRect? = nil, title: String? = nil,
             url: String? = nil, identifier: String? = nil) {
            attributes = ["AXRole": role]
            attributes["AXTitle"] = title; attributes["AXURL"] = url; attributes["AXDOMIdentifier"] = identifier
            self.children = children; self.frame = frame
        }
    }
    let viewport = CGRect(x: 0, y: 114, width: 280, height: 990)
    let pinned = CGRect(x: 6, y: 172, width: 64, height: 38)
    let regular = CGRect(x: 6, y: 216, width: 268, height: 38)
    let second = CGRect(x: 6, y: 254, width: 268, height: 38)
    let tabs = [
        BrowserTabItem(id: 6, windowID: 10, index: 0, title: "Pinned", url: "https://example.org", active: false, pinned: true),
        BrowserTabItem(id: 51, windowID: 10, index: 1, title: "Same title", url: "https://example.com/one", active: true),
        BrowserTabItem(id: 52, windowID: 10, index: 2, title: "Same title", url: "https://example.com/two", active: false)
    ]
    // Deidentified live Firefox/Sidebery shape: browser-owned webarea, nested
    // extension document, row DOM identities, icon-only pinned card, deep label
    // leaves and a duplicate hover-preview label outside the actual row.
    let rows: [Int: Node] = [
        0: .init("AXWindow", children: [1, 20]),
        1: .init("AXWebArea", children: [2], frame: viewport, url: "chrome://browser/content/webext-panels.xhtml"),
        2: .init("AXScrollArea", children: [3]),
        3: .init("AXWebArea", children: [4, 5, 7, 9], url: "moz-extension://fixture/sidebar/sidebar.html"),
        4: .init("AXGroup", children: [10], frame: pinned, identifier: "tab6"),
        5: .init("AXGroup", children: [6], frame: regular, identifier: "tab51"),
        6: .init("AXStaticText", frame: regular.insetBy(dx: 32, dy: 8), title: "Same title"),
        7: .init("AXGroup", children: [8], frame: second, identifier: "tab52"),
        8: .init("AXStaticText", frame: second.insetBy(dx: 32, dy: 8), title: "Same title"),
        9: .init("AXStaticText", frame: CGRect(x: 20, y: 400, width: 220, height: 20), title: "Same title"),
        10: .init("AXImage", children: [11]),
        11: .init("AXStaticText", title: "Decorative SVG"),
        20: .init("AXWebArea", children: [21], frame: viewport, url: "https://example.com/page"),
        21: .init("AXGroup", frame: regular, identifier: "tab51")
    ]
    func scan(_ fixture: [Int: Node] = rows, selected: Set<Int>, complete: Bool = true, limit: Int = 1800,
              browser: String = "org.mozilla.firefox") -> WorkspaceTabOutlineScan {
        WorkspaceTabOutlineScanner.scan(root: 0, browser: browser, tabs: tabs, selected: selected,
            reader: .init(text: { fixture[$0]?.attributes[$1] }, children: { fixture[$0]?.children ?? [] },
                frame: { fixture[$0]?.frame }, key: { $0 }, equal: { $0 == $1 },
                hasTime: { true }, readsComplete: { complete }), nodeLimit: limit)
    }
    let pinnedOnly = scan(selected: [6])
    try expect(pinnedOnly.complete && pinnedOnly.regions == [pinned.insetBy(dx: 1, dy: 1)],
               "Actual sidebar scanner outlines icon-only pinned rows by exact tab identity")
    let oneDuplicate = scan(selected: [51])
    try expect(oneDuplicate.regions == [regular.insetBy(dx: 1, dy: 1)],
               "One of two same-title Sidebery tabs marks only its exact row, not a hover preview")
    try expect(scan(selected: [51, 52]).regions == [regular.insetBy(dx: 1, dy: 1), second.insetBy(dx: 1, dy: 1)],
               "Two selected same-title rows remain two separate exact marks without duplicated tooltip outlines")
    try expect(scan(selected: [999]).regions.isEmpty, "Sidebar IDs absent from the verified window snapshot never receive a mark")
    var wrongID = rows; wrongID[5]?.attributes["AXDOMIdentifier"] = "tab999"
    try expect(scan(wrongID, selected: [51]).regions.isEmpty, "An unknown exact row cannot fall back to another tab with the same title")
    try expect(scan(selected: [51], browser: "com.google.Chrome").regions.isEmpty,
               "Only Firefox's browser-owned sidebar may expose nested extension rows; page ARIA/DOM IDs never do")
    var embeddedPage = rows
    embeddedPage[3]?.children = [20]
    try expect(scan(embeddedPage, selected: [51]).regions.isEmpty,
               "A web page embedded inside a browser-owned sidebar still cannot impersonate a native tab")
    try expect(!scan(selected: [6], complete: false).complete,
               "A failed AX read is incomplete even if the remaining traversal reaches its end")
    try expect(!scan(selected: [6], limit: 4).complete, "Discarding queued AX descendants at the node cap is never a completed empty scan")
    try expect(!scan([0: .init("AXWindow")], selected: [51]).complete,
               "An unavailable browser chrome subtree is not evidence that all tab marks disappeared")
    var missing = rows; missing[3]?.children = []
    let empty = scan(missing, selected: [51])
    try expect(empty.complete && empty.regions.isEmpty, "A confirmed empty browser sidebar clears prior marks")
    var invalid = rows; invalid[5]?.frame = .null
    try expect(!scan(invalid, selected: [51]).complete, "Unavailable or nonfinite selected-row geometry cannot certify disappearance")
    var continuity = TabBlurContinuity()
    let now = Date()
    _ = continuity.update(oneDuplicate.regions, context: "window:session:selection", complete: true, now: now)
    try expect(continuity.update([], context: "window:session:selection", complete: false, now: now.addingTimeInterval(0.35)) == oneDuplicate.regions,
               "An AX timeout preserves recently validated row geometry within the existing bounded continuity window")
    try expect(continuity.update(empty.regions, context: "window:session:selection", complete: empty.complete, now: now.addingTimeInterval(0.36)).isEmpty,
               "A subsequent complete empty scan removes the preserved mark immediately")
    let horizontal: [Int: Node] = [
        0: .init("AXWindow", children: [1]), 1: .init("AXTabGroup", children: [2, 3, 4]),
        2: .init("AXRadioButton", frame: pinned), 3: .init("AXRadioButton", frame: regular), 4: .init("AXTab", frame: second)
    ]
    try expect(scan(horizontal, selected: [51], browser: "com.google.Chrome").regions == [regular.insetBy(dx: 1, dy: 1)],
               "Native horizontal/vertical tab groups retain exact ordered mapping alongside the sidebar fix")
    var labelled = horizontal
    labelled[2]?.attributes["AXTitle"] = "Pinned"
    labelled[3]?.attributes["AXTitle"] = "Same title"
    labelled[4]?.attributes["AXTitle"] = "Same title"
    try expect(scan(labelled, selected: [51], browser: "com.google.Chrome").complete
        && scan(labelled, selected: [51], browser: "com.google.Chrome").regions == [regular.insetBy(dx: 1, dy: 1)],
        "Consistent native labels preserve exact indices even when separate tabs have duplicate titles")
    var reordered = labelled
    reordered[2]?.attributes["AXTitle"] = "Same title"
    reordered[3]?.attributes["AXTitle"] = "Pinned"
    let staleOrder = scan(reordered, selected: [51], browser: "com.google.Chrome")
    try expect(!staleOrder.complete && staleOrder.identityContradiction && staleOrder.regions.isEmpty,
        "A tab reordered between correlated discovery and native AX traversal cannot paint another tab by stale index or title fallback")
    var orderContinuity = TabBlurContinuity()
    _ = scan(labelled, selected: [51], browser: "com.google.Chrome").updateContinuity(&orderContinuity, context: "unchanged-receipt", now: now)
    try expect(staleOrder.updateContinuity(&orderContinuity, context: "unchanged-receipt", now: now.addingTimeInterval(0.1)).isEmpty,
        "A positively contradicted order immediately removes an already drawn contour rather than retaining wrong coordinates")
    _ = scan(labelled, selected: [51], browser: "com.google.Chrome").updateContinuity(&orderContinuity, context: "unchanged-receipt", now: now)
    let unavailable = scan(horizontal, selected: [51], complete: false, browser: "com.google.Chrome")
    try expect(!unavailable.identityContradiction
        && !unavailable.updateContinuity(&orderContinuity, context: "unchanged-receipt", now: now.addingTimeInterval(0.1)).isEmpty,
        "An ordinary incomplete AX read still preserves bounded known-good outline geometry")
    var navigated = labelled
    navigated[3]?.attributes["AXTitle"] = "A newly navigated page"
    try expect(!scan(navigated, selected: [51], browser: "com.google.Chrome").complete
        && scan(navigated, selected: [51], browser: "com.google.Chrome").regions.isEmpty,
        "A meaningful native title absent from the discovery cohort requires a fresh receipt instead of assuming positional identity")
    var descriptions = horizontal
    descriptions[2]?.attributes["AXDescription"] = "Pinned tab"
    descriptions[2]?.attributes["AXValue"] = "0"
    descriptions[3]?.attributes["AXDescription"] = "Same title - Memory usage - 200 MB"
    descriptions[3]?.attributes["AXValue"] = "1"
    descriptions[4]?.attributes["AXDescription"] = "Same title — Google Chrome – QA Profile"
    try expect(scan(descriptions, selected: [6, 51, 52], browser: "com.google.Chrome").complete
        && scan(descriptions, selected: [6, 51, 52], browser: "com.google.Chrome").regions.count == 3,
        "Chrome memory descriptions, native title decorations and unlabeled pinned controls do not falsely invalidate an exact cohort")
    descriptions[3]?.attributes["AXDescription"] = "Pinned - Memory usage - 100 MB"
    try expect(!scan(descriptions, selected: [51], browser: "com.google.Chrome").complete
        && scan(descriptions, selected: [51], browser: "com.google.Chrome").regions.isEmpty,
        "Decorated descriptions still expose a contradictory tab identity and cannot bypass reorder detection")
    // Deidentified current Sidebery AX: the row owns tab identity, but its
    // background child owns the painted shape. The row's six-point trailing
    // padding and tree indentation are outside that shape.
    var painted = rows
    let regularBody = CGRect(x: 6, y: 216, width: 268, height: 32)
    painted[5]?.children = [15, 6]
    painted[15] = .init("AXGroup", frame: regularBody)
    try expect(scan(painted, selected: [51]).regions == [regularBody.insetBy(dx: 1, dy: 1)],
               "A native Sidebery outline follows the actual painted background without including trailing row spacing")
    let indentedBody = CGRect(x: 20, y: 216, width: 254, height: 32)
    painted[15]?.frame = indentedBody
    try expect(scan(painted, selected: [51]).regions == [indentedBody.insetBy(dx: 1, dy: 1)],
               "Tree-indented tabs retain their native background width and x position instead of boxing the full outer row")
    let configuredBody = CGRect(x: 26, y: 216, width: 248, height: 29)
    painted[15]?.frame = configuredBody
    try expect(scan(painted, selected: [51]).regions == [configuredBody.insetBy(dx: 1, dy: 1)],
               "Changed sidebar spacing and indentation use current native geometry rather than a hard-coded six-point correction")
    painted[4]?.children = [16, 10]
    let pinnedBody = CGRect(x: pinned.minX, y: pinned.minY, width: pinned.width, height: 32)
    painted[16] = .init("AXGroup", frame: pinnedBody)
    try expect(scan(painted, selected: [6]).regions == [pinnedBody.insetBy(dx: 1, dy: 1)],
               "Icon-only pinned tabs also use their exact painted native background")
    painted[5]?.children = [17, 15, 6]
    painted[17] = .init("AXGroup", frame: regularBody)
    try expect(scan(painted, selected: [51]).regions == [regular.insetBy(dx: 1, dy: 1)],
               "Two distinct candidate background shapes retain the exact row instead of guessing an inner shape")
    painted[17]?.frame = configuredBody
    try expect(scan(painted, selected: [51]).regions == [configuredBody.insetBy(dx: 1, dy: 1)],
               "Repeated AX background geometry yields one outline rather than duplicated contours")
    painted[5]?.children = [15, 6]
    painted[15]?.frame = configuredBody.offsetBy(dx: 0, dy: -100)
    try expect(scan(painted, selected: [51]).regions == [regular.insetBy(dx: 1, dy: 1)],
               "An unrelated or stale child outside its identified row cannot displace the current tab outline")
    painted[15]?.frame = configuredBody
    painted[15]?.children = [6]
    try expect(scan(painted, selected: [51]).regions == [regular.insetBy(dx: 1, dy: 1)],
               "A label container with descendants cannot impersonate the empty painted tab background")
    painted[15]?.children = []
    painted[3]?.frame = CGRect(x: 0, y: 225, width: 280, height: 300)
    try expect(scan(painted, selected: [51]).regions == [configuredBody.intersection(painted[3]!.frame!).insetBy(dx: 1, dy: 1)],
               "A partially scrolled tab outline is clipped to the actual extension viewport, never its browser header")
    var cohort = rows
    cohort[3]?.children = [4, 30]
    cohort[30] = .init("AXGroup", children: [5, 7], frame: CGRect(x: 0, y: 216, width: 280, height: 100))
    try expect(scan(cohort, selected: [51]).regions == [regular.insetBy(dx: 1, dy: 1)],
               "A complete fitting Sidebery row cohort with consistent geometry remains visible")
    var stale = cohort
    stale[5]?.frame = regular.offsetBy(dx: 0, dy: -100)
    stale[7]?.frame = second.offsetBy(dx: 0, dy: -100)
    let displaced = scan(stale, selected: [51, 52])
    try expect(!displaced.complete && displaced.regions.isEmpty,
               "A whole fitting row cohort displaced outside its container is incomplete, never drawn over other sidebar controls")
    var scrollable = stale
    scrollable[30]?.frame = CGRect(x: 0, y: 130, width: 280, height: 50)
    try expect(scan(scrollable, selected: [51]).complete && !scan(scrollable, selected: [51]).regions.isEmpty,
               "A genuinely scrollable row cohort taller than its viewport is not misclassified as stale fitting geometry")
    var subset = stale
    subset[30]?.children = [5]
    try expect(scan(subset, selected: [51]).complete,
               "A clipped or collapsed subset cannot establish a whole-cohort geometry inconsistency")
    var offscreen = subset
    offscreen[5]?.frame = regular.offsetBy(dx: 0, dy: -200)
    try expect(scan(offscreen, selected: [51]).complete && scan(offscreen, selected: [51]).regions.isEmpty,
               "A legitimately offscreen selected row still clears its outline after a complete read")
    var partial = cohort
    partial[30]?.frame = CGRect(x: 0, y: 100, width: 280, height: 100)
    partial[5]?.frame = CGRect(x: 6, y: 110, width: 268, height: 38)
    partial[7]?.frame = CGRect(x: 6, y: 148, width: 268, height: 38)
    try expect(scan(partial, selected: [51]).complete && !scan(partial, selected: [51]).regions.isEmpty,
               "A consistent tree partly outside the sidebar clips its row without treating the document as failed")

    // Live Firefox follow-up: AXWindows listed only a minimized sibling, while
    // AXFocusedWindow and AXMainWindow both exposed the other standard window.
    // Exercise the production root resolver and walker, not just union logic.
    let windowFrame = CGRect(x: 0, y: 39, width: 1710, height: 1073)
    var roots = rows
    roots[0]?.frame = windowFrame; roots[0]?.attributes["AXTitle"] = "Current browser window"
    roots[100] = .init("AXWindow", frame: windowFrame, title: "Minimized sibling")
    roots[101] = .init("AXWindow", frame: windowFrame, title: "Current browser window")
    let rootReader = WorkspaceTabOutlineReader<Int>(text: { roots[$0]?.attributes[$1] },
        children: { roots[$0]?.children ?? [] }, frame: { roots[$0]?.frame }, key: { $0 }, equal: { $0 == $1 },
        hasTime: { true }, readsComplete: { true })
    func root(_ listed: [Int], focused: Int? = nil, main: Int? = nil, minimized: Set<Int> = [100]) -> Int? {
        WorkspaceTabOutlineScanner.windowRoot(listed: listed, focused: focused, main: main,
            targetFrame: windowFrame, targetTitle: "Current browser window", reader: rootReader,
            isMinimized: minimized.contains)
    }
    let missingListedRoot = root([100], focused: 0, main: 0)
    let recovered = missingListedRoot.map {
        WorkspaceTabOutlineScanner.scan(root: $0, browser: "org.mozilla.firefox", tabs: tabs, selected: [51], reader: rootReader)
    }
    try expect(missingListedRoot == 0 && recovered?.complete == true && recovered?.regions == [regular.insetBy(dx: 1, dy: 1)],
               "A standard Firefox window omitted from AXWindows still gets its own exact sidebar outline through focused/main roots")
    try expect(root([0], focused: 0, main: 0) == 0,
               "The same AX object listed, focused and main is deduplicated rather than treated as ambiguous windows")
    try expect(root([100], main: 0) == 0,
               "A main-window root remains available when AXFocusedWindow is absent")
    try expect(root([100]) == nil,
               "A minimized sibling with the requested frame is never a substitute for an unavailable visible window")
    try expect(root([100], focused: 0, minimized: []) == 0,
               "Overlapping distinct windows still require the requested title instead of preferring arbitrary enumeration order")
    try expect(root([0], focused: 101, minimized: []) == nil,
               "Distinct overlapping same-title roots remain ambiguous even when one is focused")
    roots[100]?.frame = windowFrame.offsetBy(dx: 100, dy: 0)
    try expect(root([100], minimized: []) == nil,
               "Additional AX roots never waive the requested native-window geometry")
    try expect(root([0], focused: 0, minimized: [0]) == nil,
               "Even a focused candidate cannot resurrect an outline on a confirmed minimized window")
}
