import Foundation

/// Pure key-state logic, independent of UI/event-tap delivery.
public struct QuickMarkGesture {
    public enum Action: Equatable { case single, mark, run, toggleMode }
    public struct Result { public let consume: Bool; public let action: Action? }
    public static let doublePressInterval: TimeInterval = 0.28
    private var held = false
    private var usedChord = false
    private var pendingSingle: TimeInterval?
    private var swallowed: Set<Int> = []
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func expire(now: TimeInterval) -> Action? {
        guard !held, let deadline = pendingSingle, now >= deadline else { return nil }
        pendingSingle = nil
        return .single
    }
    public mutating func key(code: Int, down: Bool, modified: Bool, repeatKey: Bool, now: TimeInterval) -> Result {
        if !down, swallowed.remove(code) != nil { return .init(consume: true, action: nil) }
        if code == 50 {
            if !down {
                guard held else { return .init(consume: false, action: nil) }
                held = false
                if !usedChord { pendingSingle = now + Self.doublePressInterval }
                return .init(consume: true, action: nil)
            }
            guard !modified else { pendingSingle = nil; return .init(consume: false, action: nil) }
            if repeatKey || held { return .init(consume: true, action: nil) }
            held = true; usedChord = false
            if let deadline = pendingSingle, now <= deadline {
                pendingSingle = nil; usedChord = true
                return .init(consume: true, action: .mark)
            }
            pendingSingle = nil
            return .init(consume: true, action: nil)
        }
        if down, held, !modified, [36, 76, 44].contains(code) {
            guard !repeatKey, !usedChord else { return .init(consume: true, action: nil) }
            usedChord = true; pendingSingle = nil; swallowed.insert(code)
            return .init(consume: true, action: code == 44 ? .toggleMode : .run)
        }
        // Typing another key cancels an incomplete gesture; never open a picker
        // behind ongoing typing or a Command/Shift shortcut.
        if down { pendingSingle = nil; if held { usedChord = true } }
        return .init(consume: false, action: nil)
    }
}
