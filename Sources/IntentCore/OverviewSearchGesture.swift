import Foundation

/// Immediate overview exit and held-prefix controls. Search belongs to Apple Spotlight.
public struct OverviewSearchGesture {
    public enum Action: Equatable { case close, clear, modification(Int), mode, run, savedSlot(Int) }
    public struct Result { public let consume: Bool; public let action: Action? }
    private var held = false
    private var usedChord = false
    public init() {}
    public mutating func key(code: Int, down: Bool, modified: Bool, repeated: Bool, editing: Bool) -> Result {
        if code == 53, down, !modified {
            let action: Action = held ? .clear : .close
            held = false; return .init(consume: true, action: action)
        }
        if down, held, !modified {
            let numbers = [18, 19, 20, 21, 23, 22]
            let action: Action? = numbers.firstIndex(of: code).map(Action.modification)
                ?? (code == 11 ? .mode : ([36, 76].contains(code) ? .run : nil))
            if let action { usedChord = true; return .init(consume: true, action: repeated ? nil : action) }
        }
        if !held, !modified, !editing, let index = [18, 19, 20, 21, 23, 22, 26, 28, 25].firstIndex(of: code) {
            return .init(consume: true, action: down && !repeated ? .savedSlot(index) : nil)
        }
        guard code == 50, !modified else { return .init(consume: false, action: nil) }
        if !down {
            guard held else { return .init(consume: false, action: nil) }
            held = false; return .init(consume: true, action: usedChord ? nil : .close)
        }
        if held || repeated { return .init(consume: true, action: nil) }
        guard !editing else { return .init(consume: false, action: nil) }
        held = true; usedChord = false; return .init(consume: true, action: nil)
    }
}
