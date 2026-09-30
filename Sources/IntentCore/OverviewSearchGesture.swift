import Foundation

/// Routes overview search independently of the global single/double-tap gesture.
public struct OverviewSearchGesture {
    public enum Action: Equatable { case search, released, close, clear, modification(Int), mode, run }
    public struct Result { public let consume: Bool; public let action: Action? }
    private var held = false
    public init() {}
    public mutating func key(code: Int, down: Bool, modified: Bool, repeated: Bool, editing: Bool, hasSearchQuery: Bool = false) -> Result {
        if code == 53, down, !modified {
            let action: Action = held ? .clear : .close
            held = false; return .init(consume: true, action: action)
        }
        if down, held, !modified {
            if [36, 76].contains(code), !hasSearchQuery {
                return .init(consume: true, action: repeated ? nil : .run)
            }
            let numbers = [18, 19, 20, 21, 23, 22]
            let action: Action? = numbers.firstIndex(of: code).map(Action.modification)
                ?? (code == 11 ? .mode : nil)
            if let action { return .init(consume: true, action: repeated ? nil : action) }
        }
        guard code == 50, !modified else { return .init(consume: false, action: nil) }
        if !down {
            guard held else { return .init(consume: false, action: nil) }
            held = false; return .init(consume: true, action: .released)
        }
        if held || repeated { return .init(consume: true, action: nil) }
        guard !editing else { return .init(consume: false, action: nil) }
        held = true; return .init(consume: true, action: .search)
    }
}
