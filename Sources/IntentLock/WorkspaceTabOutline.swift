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
        func windowElement(_ key: String) -> AXUIElement? {
            guard let result = value(app, key), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(result, to: AXUIElement.self)
        }
        let reader = WorkspaceTabOutlineReader(text: text, children: children, frame: frame,
            key: { Int(CFHash($0)) }, equal: { CFEqual($0, $1) },
            hasTime: { Date() < deadline }, readsComplete: { readsComplete })
        guard let root = WorkspaceTabOutlineScanner.windowRoot(listed: windows,
            focused: windowElement(kAXFocusedWindowAttribute), main: windowElement(kAXMainWindowAttribute),
            targetFrame: window.frame, targetTitle: window.title, reader: reader,
            isMinimized: { value($0, kAXMinimizedAttribute) as? Bool == true }) else { return ([], false) }
        return WorkspaceTabOutlineScanner.scan(root: root, browser: window.bundle, tabs: tabs, selected: selected, reader: reader)
    }
}
