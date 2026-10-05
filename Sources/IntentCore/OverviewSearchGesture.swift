import Foundation

/// Immediate overview exit and held-prefix controls. Search belongs to Apple Spotlight.
public struct OverviewSearchGesture {
    public enum Action: Equatable { case close, clear, modification(Int), mode, run, savedSlot(Int) }
    public struct Result { public let consume: Bool; public let action: Action? }
    private var held = false
    private var usedChord = false
    private var runIssued = false
    private var swallowed: Set<Int> = []
    public init() {}
    public mutating func key(code: Int, down: Bool, modified: Bool, repeated: Bool, editing: Bool, capsLockHeld: Bool = false) -> Result {
        if !down, swallowed.remove(code) != nil { return .init(consume: true, action: nil) }
        if code == 53, down, !modified {
            let action: Action = held ? .clear : .close
            swallowed.insert(code)
            if held { swallowed.insert(50) }
            held = false; return .init(consume: true, action: repeated ? nil : action)
        }
        if code == 57, down, held, capsLockHeld, !modified {
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
        guard !editing else { return .init(consume: false, action: nil) }
        held = true; usedChord = capsLockHeld; runIssued = capsLockHeld
        return .init(consume: true, action: capsLockHeld ? .run : nil)
    }
}
