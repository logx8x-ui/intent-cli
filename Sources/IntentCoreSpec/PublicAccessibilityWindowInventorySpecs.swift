import ApplicationServices
import Foundation
import IntentCore
import IntentLock

private struct AccessibilityRootToken: Equatable {
    let object: Int
    var role: String? = kAXWindowRole
    var pid: Int32? = 42
}

func runPublicAccessibilityWindowInventorySpecs() throws {
    typealias Inventory = PublicAccessibilityWindowInventory
    typealias Value = Inventory.Value<AccessibilityRootToken>
    let first = AccessibilityRootToken(object: 1)
    let alias = AccessibilityRootToken(object: 1)
    let second = AccessibilityRootToken(object: 2)
    let menu = AccessibilityRootToken(object: 3, role: kAXMenuBarRole, pid: nil)
    func collect(_ windows: Value = .array([]), children: Value = .absent,
                 main: Value = .absent, focused: Value = .absent,
                 maximumCount: Int = 64, hasTime: () -> Bool = { true },
                 onRead: (Inventory.Attribute) -> Void = { _ in },
                 onRole: (AccessibilityRootToken) -> Void = { _ in },
                 onPID: (AccessibilityRootToken) -> Void = { _ in }) -> [AccessibilityRootToken]? {
        Inventory.collect(pid: 42, maximumCount: maximumCount, hasTime: hasTime, read: {
            onRead($0)
            switch $0 {
            case .windows: return windows
            case .children: return children
            case .mainWindow: return main
            case .focusedWindow: return focused
            }
        }, role: { onRole($0); return $0.role }, processID: { onPID($0); return $0.pid },
        equal: { $0.object == $1.object })
    }

    let exposed = collect(children: .array([menu]), main: .element(first), focused: .element(alias))
    try expect(exposed?.map(\.object) == [1],
        "AXWindows=[] still discovers the positively exposed main/focused window without treating a menu bar as a window")
    try expect(collect(.array([first]), children: .array([alias, second, menu]),
        main: .element(second), focused: .element(first))?.map(\.object) == [1, 2],
        "The production collector unions public roots and deduplicates the same AX identity across sources")
    try expect(collect(children: .array([first, second]))?.map(\.object) == [1, 2],
        "Direct application child windows are discovered even without main or focused attributes")
    for primary in [[], [first]] {
        let observation = Inventory.collectObservation(pid: 42, hasTime: { true }, read: { source -> Value in
            source == .windows ? .array(primary) : source == .mainWindow ? .element(alias) : .absent
        }, role: { $0.role }, processID: { $0.pid }, equal: { $0.object == $1.object })
        try expect(observation?.primaryWindows.map(\.object) == primary.map(\.object)
            && observation?.windows.map(\.object) == [1]
            && observation?.primaryWasSupplemented == primary.isEmpty,
            "Supplementary positive roots retain their primary provenance and cannot authorize negative enumeration evidence")
    }

    // Positive roots do not invent omitted siblings or authorize an ambiguous
    // native counterpart. Use the existing exact native binding policy as well.
    typealias Binding = PermittedWindowRecoveryPolicy
    let identity = Binding.Identity(bundleIdentifier: "test.app", pid: 42, launched: 100, windowID: 1)
    let frame = CGRect(x: 20, y: 40, width: 800, height: 600)
    let native = [Binding.Window(identity: identity, title: "Study", frame: frame),
        .init(identity: .init(bundleIdentifier: "test.app", pid: 42, launched: 100, windowID: 2),
              title: "Other", frame: CGRect(x: 40, y: 60, width: 800, height: 600))]
    try expect(exposed?.count == 1 && Binding.uniquelyMatches(expected: identity, title: "Study", frame: frame, native: native),
        "A discovered exact root can bind its proven native window while an omitted sibling stays unexposed")
    let twin = Binding.Window(identity: .init(bundleIdentifier: "test.app", pid: 42, launched: 100, windowID: 2), title: "Study", frame: frame)
    try expect(!Binding.uniquelyMatches(expected: identity, title: "Study", frame: frame, native: [native[0], twin]),
        "A positive root does not relax reverse native uniqueness for indistinguishable siblings")

    for primary in [Value.failed, .absent, .element(first)] {
        var reads: [Inventory.Attribute] = []
        try expect(collect(primary, main: .element(first), onRead: { reads.append($0) }) == nil && reads == [.windows],
            "A failed, absent or malformed primary enumeration stays unknown and cannot be rescued as complete by a main root")
    }
    for source in [Inventory.Attribute.children, .mainWindow, .focusedWindow] {
        try expect(collect(.array([first]), children: source == .children ? .failed : .absent,
            main: source == .mainWindow ? .failed : .absent,
            focused: source == .focusedWindow ? .failed : .absent) == nil,
            "A failed optional root read stays unknown: \(source)")
    }
    try expect(collect()?.isEmpty == true && collect(.array([first]))?.map(\.object) == [1],
        "Unsupported or absent optional roots are harmless; successful empty roots remain only an empty positive list")
    try expect(collect(children: .element(first)) == nil && collect(main: .array([first])) == nil
        && collect(focused: .array([first])) == nil,
        "Wrong public attribute value shapes fail instead of silently discarding candidates")
    for invalid in [AccessibilityRootToken(object: 4, role: nil),
                    .init(object: 4, role: kAXWindowRole, pid: nil),
                    .init(object: 4, role: kAXWindowRole, pid: 99)] {
        try expect(collect(.array([invalid])) == nil && collect(children: .array([invalid])) == nil
            && collect(main: .element(invalid)) == nil && collect(focused: .element(invalid)) == nil,
            "Unreadable or foreign-process window roots never enter the exact binding inventory")
    }
    try expect(collect(.array([menu])) == nil && collect(main: .element(menu)) == nil
        && collect(focused: .element(menu)) == nil,
        "An explicitly required window root cannot be replaced by a non-window application object")
    var pidReads = 0
    try expect(collect(children: .array([menu]), onPID: { _ in pidReads += 1 })?.isEmpty == true && pidReads == 0,
        "An ordinary MenuBar child is skipped without requiring it to carry window process metadata")

    try expect(collect(maximumCount: 0) == nil && collect(maximumCount: 257) == nil
        && collect(.array([first, second]), maximumCount: 1) == nil
        && collect(children: .array([first, second]), maximumCount: 1) == nil
        && collect(.array([first]), main: .element(second), maximumCount: 1) == nil,
        "Both individual root arrays and the distinct combined inventory enforce the bounded limit")
    try expect(collect(.array([first]), main: .element(alias), focused: .element(first), maximumCount: 1)?.count == 1,
        "Duplicate root aliases do not consume another distinct-window slot")
    var reads = 0
    try expect(collect(hasTime: { false }, onRead: { _ in reads += 1 }) == nil && reads == 0,
        "An expired deadline performs no public AX read")
    for expireDuring in ["read", "role", "pid"] {
        var current = true
        let result = collect(.array([first]), hasTime: { current },
            onRead: { _ in if expireDuring == "read" { current = false } },
            onRole: { _ in if expireDuring == "role" { current = false } },
            onPID: { _ in if expireDuring == "pid" { current = false } })
        try expect(result == nil, "Deadline expiry during \(expireDuring) discards a partial inventory instead of publishing false completeness")
    }

    // Construct opaque AX references only: no attribute read, permission request,
    // activation, window creation or desktop inventory is involved in decoding.
    let reference = AXUIElementCreateApplication(42)
    let decoded = Inventory.validatedElements(in: [reference] as NSArray)
    try expect(decoded?.count == 1 && decoded.map { CFEqual($0[0], reference) } == true,
        "The production native decoder retains genuine AX element references")
    try expect(Inventory.validatedElements(in: [] as NSArray)?.isEmpty == true
        && Inventory.validatedElements(in: "not an array" as NSString) == nil
        && Inventory.validatedElements(in: ["not an AX element"] as NSArray) == nil
        && Inventory.validatedElements(in: [reference, "foreign object"] as NSArray) == nil
        && Inventory.validatedElements(in: [reference, reference] as NSArray, maximumCount: 1) == nil,
        "Actual malformed CF arrays, foreign members and oversized native arrays fail before any AX API consumes a member")
}
