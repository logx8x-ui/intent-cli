import AppKit
import SwiftUI
import IntentCore

/// Local to Intent's overview; never changes the user's global trackpad or
/// desktop-switching settings. A visible Tasks control provides mouse access.
@MainActor
final class OverviewPageHostingView<Content: View>: NSHostingView<Content> {
    var onPageSwipe: ((OverviewPageSwipe.Direction) -> Void)? {
        didSet { allowedTouchTypes = onPageSwipe == nil ? [] : [.indirect] }
    }
    var onPageProgress: ((CGFloat, Bool) -> Void)?
    private var recognizer = OverviewPageSwipe()
    private var contactIDs: [AnyHashable: Int] = [:]
    private var nextContactID = 0

    override func touchesBegan(with event: NSEvent) {
        // A cancelled system gesture may not deliver a later empty ended event.
        // All-new contacts start a new sequence; adding/replacing one does not.
        let active = event.touches(matching: .touching, in: self)
        if !active.isEmpty && active.allSatisfy({ $0.phase == .began }) {
            recognizer.reset(); contactIDs.removeAll(); nextContactID = 0
        }
        track(event)
    }
    override func touchesMoved(with event: NSEvent) { track(event) }
    override func touchesEnded(with event: NSEvent) { track(event) }
    override func touchesCancelled(with event: NSEvent) {
        _ = recognizer.update(contacts: [:], cancelled: true)
        onPageProgress?(0, true)
        contactIDs.removeAll(); nextContactID = 0
    }

    private func track(_ event: NSEvent) {
        guard let onPageSwipe, window?.isKeyWindow == true else {
            recognizer.reset(); contactIDs.removeAll(); onPageProgress?(0, true); return
        }
        let touches = event.touches(matching: .touching, in: self).filter { $0.type == .indirect && !$0.isResting }
        var contacts: [Int: CGPoint] = [:]
        for touch in touches {
            guard let identity = touch.identity as? NSObject else { recognizer.reset(); return }
            let key = AnyHashable(identity)
            if contactIDs[key] == nil { nextContactID += 1; contactIDs[key] = nextContactID }
            contacts[contactIDs[key]!] = touch.normalizedPosition
        }
        let direction = recognizer.update(contacts: contacts, cancelled: NSEvent.pressedMouseButtons != 0)
        if let direction { onPageSwipe(direction) }
        else { onPageProgress?(recognizer.progress, contacts.isEmpty || recognizer.progress == 0) }
        if contacts.isEmpty { contactIDs.removeAll(); nextContactID = 0 }
    }
}
