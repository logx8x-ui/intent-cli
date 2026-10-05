import CoreGraphics
import Foundation
import IOKit.hidsystem

/// The native event boundary for Quick Focus. Keep this shared with regression
/// tests: a correct gesture reducer cannot repair an incorrectly decoded key.
public struct QuickMarkKeyboardInput {
    public let code: Int
    public let down: Bool
    public let modified: Bool
    public let repeatKey: Bool
    public let capsLockHeld: Bool
    public let opensSpotlight: Bool
}

public struct QuickMarkKeyboardNormalizer {
    private var capsLockWasHeld = false
    private static let shortcutModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
    // AlphaShift (and CGEventSource.keyState for key 57) describes the capitals
    // latch, not a held key. The HID stateless bits describe physical key-down.
    // Reading the event itself also avoids querying state from a later event.
    private static let physicalCapsLockMask = UInt64(NX_ALPHASHIFT_STATELESS_MASK | NX_DEVICE_ALPHASHIFT_STATELESS_MASK)

    public init() {}

    public mutating func normalize(type: CGEventType, event: CGEvent) -> QuickMarkKeyboardInput? {
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return nil }
        let flags = event.flags
        let capsLockHeld = flags.rawValue & Self.physicalCapsLockMask != 0
        let capsLockPressed = capsLockHeld && !capsLockWasHeld
        capsLockWasHeld = capsLockHeld
        let modifiers = flags.intersection(Self.shortcutModifiers)
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .flagsChanged {
            // Stateless Caps events may use keycode 0xff rather than 57. Only
            // the physical rising edge may complete backtick-then-Caps Run;
            // latch changes, releases and other modifier changes must not.
            guard capsLockPressed else { return nil }
            return QuickMarkKeyboardInput(code: 57, down: true, modified: !modifiers.isEmpty,
                repeatKey: false, capsLockHeld: true, opensSpotlight: false)
        }

        return QuickMarkKeyboardInput(code: code, down: type == .keyDown,
            modified: !modifiers.isEmpty,
            repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            capsLockHeld: capsLockHeld,
            opensSpotlight: code == 49 && modifiers == .maskCommand)
    }
}

extension QuickMarkGesture {
    public mutating func key(_ input: QuickMarkKeyboardInput, now: TimeInterval) -> Result {
        key(code: input.code, down: input.down, modified: input.modified,
            repeatKey: input.repeatKey, now: now, capsLockHeld: input.capsLockHeld)
    }
}

/// Shared delivery policy for every normalized event, including physical Caps
/// flagsChanged. An overview-owned prefix must not be split across two reducers.
/// Spotlight gets first refusal in the native monitor before entering this route.
public enum QuickMarkKeyboardRouting {
    public enum Result {
        case overview
        case text
        case gesture
    }

    public static func route(_ input: QuickMarkKeyboardInput,
                             intentOwnsInput: Bool, editingText: Bool,
                             overviewHandler: (QuickMarkKeyboardInput) -> Bool,
                             gesture: QuickMarkGesture) -> Result {
        if intentOwnsInput, overviewHandler(input) {
            return .overview
        }
        // Opening a modifier editor must not steal an already-held prefix.
        // A new prefix begun inside an actual editor remains ordinary typing.
        if editingText && !gesture.isHoldingPrefix && !(!input.down && gesture.ownsKeyRelease(input.code)) {
            return .text
        }
        // The callback may run a modal loop or cancel input. Do not hold inout
        // access to live gesture state across that reentrant UI boundary.
        return .gesture
    }
}
