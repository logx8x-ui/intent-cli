import AppKit

/// Only explicitly registered interactive panels are exempt. Blur windows are
/// deliberately ordinary NSPanel instances and can never create an input hole.
public final class IntentInteractivePanelRegions: @unchecked Sendable {
    public static let shared = IntentInteractivePanelRegions()
    private struct Entry { let frame: CGRect; let key: Bool }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    public init() {}

    public func update(id: UUID, frame: CGRect?, isKey: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = frame.map { Entry(frame: $0, key: isKey) }
    }

    public func contains(_ point: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.values.contains { $0.frame.contains(point) }
    }

    public var hasKeyboardFocus: Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.values.contains { $0.key }
    }

    public func visibleRegions(from rectangles: [CGRect]) -> [CGRect] {
        lock.lock(); let exclusions = entries.values.map(\.frame); lock.unlock()
        return Self.subtract(exclusions, from: rectangles)
    }

    public static func subtract(_ exclusions: [CGRect], from rectangles: [CGRect]) -> [CGRect] {
        exclusions.reduce(rectangles) { pieces, excluded in
            pieces.flatMap { rect -> [CGRect] in
                let overlap = rect.intersection(excluded)
                guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
                return [
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                    CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                    CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)
                ].filter { $0.width > 0 && $0.height > 0 }
            }
        }
    }
}

/// Opt in only real Intent controls. Lifecycle updates happen on AppKit's main
/// thread; event taps and the blur scanner read the plain locked cache above.
@MainActor
open class IntentInteractivePanel: NSPanel {
    private let regionID = UUID()

    public override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                         backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateRegion), name: name, object: self)
        }
    }

    public override func orderFrontRegardless() { super.orderFrontRegardless(); updateRegion() }
    public override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin); updateRegion()
    }
    public override func orderOut(_ sender: Any?) {
        IntentInteractivePanelRegions.shared.update(id: regionID, frame: nil)
        super.orderOut(sender)
    }
    public override func close() {
        IntentInteractivePanelRegions.shared.update(id: regionID, frame: nil)
        super.close()
    }

    @objc private func updateRegion() {
        guard isVisible, !ignoresMouseEvents else {
            IntentInteractivePanelRegions.shared.update(id: regionID, frame: nil); return
        }
        let top = CGDisplayBounds(CGMainDisplayID()).height
        let rect = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        IntentInteractivePanelRegions.shared.update(id: regionID, frame: rect, isKey: isKeyWindow)
    }

    deinit { IntentInteractivePanelRegions.shared.update(id: regionID, frame: nil) }
}
