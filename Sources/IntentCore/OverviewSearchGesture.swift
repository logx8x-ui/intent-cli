import Foundation

/// Immediate overview exit and held-prefix controls. Search belongs to Apple Spotlight.
public struct OverviewSearchGesture {
    public enum Action: Equatable { case close, clear, modification(Int), mode, run, savedSlot(Int), websiteFinder }
    public struct Result { public let consume: Bool; public let action: Action? }
    private var held = false
    public var isHoldingPrefix: Bool { held }
    private var usedChord = false
    private var runIssued = false
    private var swallowed: Set<Int> = []
    public init() {}
    public mutating func key(code: Int, down: Bool, modified: Bool, repeated: Bool, editing: Bool, capsLockHeld: Bool = false, browserPickerAvailable: Bool = false) -> Result {
        if !down, swallowed.remove(code) != nil { return .init(consume: true, action: nil) }
        if code == 53, down, !modified {
            let action: Action = held ? .clear : .close
            swallowed.insert(code)
            if held { swallowed.insert(50) }
            held = false; return .init(consume: true, action: repeated ? nil : action)
        }
        // Code 57 down is a decoded Caps press edge, including the documented
        // flagsChanged path without physical stateless bits. capsLockHeld is
        // only needed when backtick arrives second; a latched state is not held.
        if code == 57, down, held, !modified {
            usedChord = true
            guard !runIssued, !repeated else { return .init(consume: true, action: nil) }
            runIssued = true
            return .init(consume: true, action: .run)
        }
        if down, held, !modified {
            let numbers = [18, 19, 20, 21, 23, 22]
            let action: Action? = numbers.firstIndex(of: code).map(Action.modification)
                ?? (code == 11 ? .mode : ([36, 76].contains(code) ? .run : nil))
            if let action {
                swallowed.insert(code)
                usedChord = true
                guard !repeated else { return .init(consume: true, action: nil) }
                if action == .run {
                    guard !runIssued else { return .init(consume: true, action: nil) }
                    runIssued = true
                }
                return .init(consume: true, action: action)
            }
        }
        if !held, !modified, !editing, let index = [18, 19, 20, 21, 23, 22, 26, 28, 25].firstIndex(of: code) {
            if down { swallowed.insert(code) }
            return .init(consume: true, action: down && !repeated ? .savedSlot(index) : nil)
        }
        if code == 17, down, !held, !modified, !editing, browserPickerAvailable {
            swallowed.insert(code)
            return .init(consume: true, action: repeated ? nil : .websiteFinder)
        }
        // Key-up belongs to the hold that consumed key-down, even if Command,
        // Shift or Option changed in between. Otherwise the prefix stays stuck.
        if code == 50, !down {
            guard held else { return .init(consume: false, action: nil) }
            held = false; return .init(consume: true, action: usedChord || modified ? nil : .close)
        }
        guard code == 50, !modified else {
            if down && held { usedChord = true }
            return .init(consume: false, action: nil)
        }
        if held || repeated { return .init(consume: true, action: nil) }
        // Overview exit is available even inside its editors. Prefix chords
        // still own the release, so editing a modifier cannot also close it.
        held = true; usedChord = capsLockHeld; runIssued = capsLockHeld
        return .init(consume: true, action: capsLockHeld ? .run : nil)
    }
}
