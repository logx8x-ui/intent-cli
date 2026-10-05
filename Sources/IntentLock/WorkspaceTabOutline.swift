import AppKit
import ApplicationServices
import IntentCore

/// Reads only browser chrome. Web page ARIA tabs must never become workspace marks.
enum WorkspaceTabOutline {
    static func scan(window: WorkspaceWindow, tabs: [BrowserTabItem], selected: Set<Int>) -> (regions: [CGRect], complete: Bool) {
        let deadline = Date(timeIntervalSinceNow: 0.12)
        var readsComplete = true
        func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard Date() < deadline else { readsComplete = false; return nil }
            AXUIElementSetMessagingTimeout(element, 0.008)
            var result: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, key as CFString, &result)
            if status != .success && status != .attributeUnsupported && status != .noValue { readsComplete = false }
            return status == .success ? result : nil
        }
        func text(_ element: AXUIElement, _ key: String) -> String? {
            guard let result = value(element, key) else { return nil }
            return result as? String ?? (key == kAXURLAttribute ? String(describing: result) : nil)
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            let result = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return result.isEmpty ? (value(element, kAXVisibleChildrenAttribute) as? [AXUIElement] ?? []) : result
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero; var size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
            return CGRect(origin: point, size: size)
        }
        let app = AXUIElementCreateApplication(window.pid)
        let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let geometryMatches = windows.filter { element in
            guard let rect = frame(element) else { return false }
            return abs(rect.minX - window.frame.minX) < 3 && abs(rect.minY - window.frame.minY) < 3
                && abs(rect.width - window.frame.width) < 3 && abs(rect.height - window.frame.height) < 3
        }
        // CGWindow and AX titles can update on different ticks after navigation.
        // A unique geometry match identifies the same native window without a
        // title race. When windows overlap, keep the title disambiguation.
        let matchingWindows = geometryMatches.count == 1 ? geometryMatches : geometryMatches.filter {
            BrowserWindowMatching.sameWindowTitle(text($0, kAXTitleAttribute) ?? "", window.title)
        }
        guard matchingWindows.count == 1, let root = matchingWindows.first else { return ([], false) }
        return WorkspaceTabOutlineScanner.scan(root: root, browser: window.bundle, tabs: tabs, selected: selected,
            reader: WorkspaceTabOutlineReader(text: text, children: children, frame: frame,
                key: { Int(CFHash($0)) }, equal: { CFEqual($0, $1) },
                hasTime: { Date() < deadline }, readsComplete: { readsComplete }))
    }
}
