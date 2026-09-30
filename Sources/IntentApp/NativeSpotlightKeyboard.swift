import AppKit

/// Product input for Apple's system search. This never implements a search UI.
enum NativeSpotlightKeyboard {
    static let dismissalTag: Int64 = 0x494E53504F544C
    static func open() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
    static func dismiss(pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)
            event?.setIntegerValueField(.eventSourceUserData, value: dismissalTag)
            event?.postToPid(pid)
        }
    }
}
