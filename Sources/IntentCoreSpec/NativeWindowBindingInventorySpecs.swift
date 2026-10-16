import CoreGraphics
import Foundation
import IntentCore
import IntentLock

func runNativeWindowBindingInventorySpecs() throws {
    typealias Inventory = NativeWindowBindingInventory
    let pid: Int32 = 615
    let bundle = "org.mozilla.firefox"
    let normalFrame = CGRect(x: 0, y: 39, width: 1710, height: 1073)
    func row(_ id: UInt32, title: String = "Blocked window", frame: CGRect? = nil,
             owner: Int32? = nil) -> [String: Any] {
        let frame = frame ?? normalFrame
        return [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: owner ?? pid,
         kCGWindowLayer as String: 0, kCGWindowName as String: title,
         kCGWindowBounds as String: ["X": frame.origin.x, "Y": frame.origin.y,
             "Width": frame.size.width, "Height": frame.size.height]]
    }
    func bindingInventory(_ rows: [[String: Any]]) -> [WorkspaceWindow]? {
        Inventory.windows(rows: rows, pid: pid, bundleIdentifier: bundle, requireUsableGeometry: false)
    }
    func matches(_ target: WorkspaceWindow, in native: [WorkspaceWindow], axFrame: CGRect? = nil) -> Bool {
        Inventory.uniquelyMatches(target: target, accessibilityTitle: target.title,
            accessibilityFrame: axFrame ?? target.frame, native: native,
            sameTitle: BrowserWindowMatching.sameWindowTitle)
    }

    // Reproduction: Firefox keeps an unrelated zero-size layer-zero surface
    // beside a normal blocked window and the selected work window.
    let blocked = row(110)
    let selected = row(6376, title: "Example Domain")
    let zero = row(100, title: "", frame: CGRect(x: 0, y: 1112, width: 0, height: 0))
    let rows = [zero, blocked, selected]
    try expect(Inventory.isOffscreen(windowID: 110, pid: pid, allRows: rows, onScreenRows: [selected]) == true,
        "A named still-live native sibling absent from a successful complete on-screen query has positive offscreen proof")
    try expect(Inventory.isOffscreen(windowID: 110, pid: pid, allRows: rows, onScreenRows: [blocked, selected]) == false,
        "Returning from Mission Control to the sibling immediately invalidates offscreen proof")
    var changedLayer = blocked; changedLayer[kCGWindowLayer as String] = 3
    try expect(Inventory.isOffscreen(windowID: 110, pid: pid, allRows: [changedLayer], onScreenRows: []) == true,
        "A tracked surface changing to layer three remains positively offscreen without losing its exact identity")
    try expect(Inventory.isOffscreen(windowID: 110, pid: pid, allRows: [changedLayer], onScreenRows: [changedLayer]) == false,
        "A nonzero-layer surface becoming visible immediately loses its offscreen proof")
    // Actual Messages failure: an admitted sibling changes layer and disappears
    // from the overview/AX enumeration, but its native lifetime remains present.
    // Feed the real parser through the tracking policy; later visibility must
    // still require hiding rather than silently dropping the obligation.
    let tracked = NativeVisibilityCoveragePolicy.Target(bundleIdentifier: "com.apple.MobileSMS",
        pid: pid, launched: 123, windowID: 110)
    var tracker = NativeOffscreenWindowCoveragePolicy()
    for (time, inventory, visible) in [(0.0, [blocked], [[String: Any]]()),
                                      (4.0, [changedLayer], [[String: Any]]()),
                                      (8.0, [changedLayer], [[String: Any]]())] {
        let outcome: NativeVisibilityCoveragePolicy.Outcome = Inventory.isOffscreen(
            windowID: 110, pid: pid, allRows: inventory, onScreenRows: visible) == true ? .offscreen : .unresolved
        try expect(tracker.update([tracked: outcome], now: time) == nil && tracker.targets.contains(tracked),
            "Layer migration cannot time out an offscreen sibling or retire its monitoring")
    }
    let returned: NativeVisibilityCoveragePolicy.Outcome = Inventory.isOffscreen(
        windowID: 110, pid: pid, allRows: [changedLayer], onScreenRows: [changedLayer]) == true ? .offscreen : .unresolved
    try expect(tracker.update([tracked: returned], now: 9) == nil,
        "A now-visible surface must regain hiding within the bounded deadline")
    try expect(tracker.update([tracked: returned], now: 9 + NativeVisibilityCoveragePolicy.deadline)?.reason == .hidingUnconfirmed,
        "A visible excluded surface still fails closed if hiding cannot be confirmed")
    var noLayer = blocked; noLayer.removeValue(forKey: kCGWindowLayer as String)
    var missingOnScreenIdentity = selected; missingOnScreenIdentity.removeValue(forKey: kCGWindowOwnerPID as String)
    for proof in [
        Inventory.isOffscreen(windowID: 110, pid: pid, allRows: nil, onScreenRows: []),
        Inventory.isOffscreen(windowID: 110, pid: pid, allRows: rows, onScreenRows: nil),
        Inventory.isOffscreen(windowID: 110, pid: pid, allRows: [selected], onScreenRows: []),
        Inventory.isOffscreen(windowID: 110, pid: pid, allRows: [noLayer], onScreenRows: []),
        Inventory.isOffscreen(windowID: 110, pid: pid, allRows: rows, onScreenRows: [row(110, owner: 616)]),
        Inventory.isOffscreen(windowID: 110, pid: pid, allRows: rows, onScreenRows: [missingOnScreenIdentity]),
        Inventory.isOffscreen(windowID: 110, pid: pid, allRows: rows, onScreenRows: [selected, selected]),
        Inventory.isOffscreen(windowID: 110, pid: pid, allRows: rows + [blocked], onScreenRows: [])
    ] {
        try expect(proof == nil,
            "Unavailable, missing, duplicate or wrong-process native identities cannot waive a window as offscreen")
    }
    guard let native = bindingInventory(rows), let target = native.first(where: { $0.id == 110 }) else {
        throw SpecFailure(description: "A zero-area sibling must not poison the exact positive native-window binding inventory")
    }
    try expect(native.count == 3 && native.contains(where: { $0.id == 100 }),
        "Exact binding retains zero-area siblings for reverse-identity ambiguity checks")
    try expect(matches(target, in: native),
        "The blocked Firefox target binds by exact native ID, title and geometry despite the zero-area sibling")
    // restore() selects the saved native ID from this same inventory before
    // resolving AX; it must not abandon a real owned window because of a sibling.
    let owned = native.first(where: { $0.id == 110 && $0.pid == pid })
    try expect(owned.map { matches($0, in: native) } == true,
        "An exactly owned restoration target remains bindable with the same zero-area sibling present")
    try expect(Inventory.windows(rows: rows, pid: pid, bundleIdentifier: bundle) == nil,
        "Default complete coverage and classification still reject a zero-area row")
    try expect(Inventory.windows(rows: [blocked, selected], pid: pid, bundleIdentifier: bundle)?.count == 2,
        "Default complete inventory keeps accepting well-formed positive-size windows")

    guard let zeroTarget = native.first(where: { $0.id == 100 }) else {
        throw SpecFailure(description: "The zero-area candidate must remain represented")
    }
    try expect(!matches(zeroTarget, in: native), "A zero-area target can never acquire or restore window ownership")
    try expect(!matches(target, in: native.filter { $0.id != 110 }),
        "A disappeared native target cannot be replaced by another browser window")
    try expect(!matches(target, in: bindingInventory([row(110, frame: .zero)]) ?? []),
        "An earlier positive target cannot bind after its current native geometry becomes zero-area")
    try expect(!matches(target, in: native, axFrame: .zero),
        "A positive native target also requires positive accessibility geometry")
    let otherProcess = Inventory.windows(rows: [row(110, owner: 616)], pid: 616, bundleIdentifier: bundle,
        requireUsableGeometry: false) ?? []
    try expect(!matches(target, in: otherProcess), "Matching title and geometry cannot borrow another process's window")

    let ambiguous = bindingInventory(rows + [row(111)]) ?? []
    try expect(!matches(target, in: ambiguous),
        "A second positive native window with the same title and geometry still prevents an AX binding")
    let tinyFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let tiny = bindingInventory([row(201, frame: tinyFrame), row(202, frame: .zero)]),
          let tinyTarget = tiny.first(where: { $0.id == 201 }) else {
        throw SpecFailure(description: "Finite nonnegative candidates remain available for the ambiguity check")
    }
    try expect(!matches(tinyTarget, in: tiny),
        "Zero-area siblings are not discarded when they overlap a tiny target within the matching tolerance")

    let malformedBounds: [[String: Any]] = [
        ["X": 0.0, "Y": 0.0, "Width": -1.0, "Height": 20.0],
        ["X": 0.0, "Y": 0.0, "Width": 20.0, "Height": -1.0],
        ["X": Double.nan, "Y": 0.0, "Width": 20.0, "Height": 20.0],
        ["X": 0.0, "Y": 0.0, "Width": Double.infinity, "Height": 20.0],
        ["X": 0.0, "Y": 0.0, "Width": 20.0],
        ["X": "unknown", "Y": 0.0, "Width": 20.0, "Height": 20.0],
        ["X": true, "Y": 0.0, "Width": 20.0, "Height": 20.0],
        ["X": 0.0, "Y": 0.0, "Width": false, "Height": 20.0]
    ]
    for badBounds in malformedBounds {
        var malformed = row(100); malformed[kCGWindowBounds as String] = badBounds
        try expect(bindingInventory([blocked, malformed]) == nil,
            "Exact-target binding does not waive negative, nonfinite or malformed sibling geometry")
        try expect(Inventory.windows(rows: [blocked, malformed], pid: pid, bundleIdentifier: bundle) == nil,
            "Complete-inventory geometry validation remains strict for malformed rows")
    }
    var missingIdentity = zero; missingIdentity.removeValue(forKey: kCGWindowNumber as String)
    var missingLayer = zero; missingLayer.removeValue(forKey: kCGWindowLayer as String)
    for malformedRows in [[blocked, missingIdentity], [blocked, missingLayer], [blocked, blocked]] {
        try expect(bindingInventory(malformedRows) == nil,
            "Missing or duplicate native identities and unknown layers remain fatal in exact-binding mode")
    }
}
