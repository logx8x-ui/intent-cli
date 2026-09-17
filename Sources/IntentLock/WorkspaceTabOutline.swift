import AppKit
import ApplicationServices
import IntentCore

/// Reads only browser chrome. Web page ARIA tabs must never become workspace marks.
enum WorkspaceTabOutline {
    static func scan(window: WorkspaceWindow, tabs: [BrowserTabItem], selected: Set<Int>) -> (regions: [CGRect], complete: Bool) {
        let deadline = Date(timeIntervalSinceNow: 0.12)
        func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.008)
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
        }
        func text(_ element: AXUIElement, _ key: String) -> String? { value(element, key) as? String }
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
        let matchingWindows = windows.filter { element in
            guard let rect = frame(element) else { return false }
            return abs(rect.minX - window.frame.minX) < 3 && abs(rect.minY - window.frame.minY) < 3
                && abs(rect.width - window.frame.width) < 3 && abs(rect.height - window.frame.height) < 3
                && BrowserWindowMatching.sameWindowTitle(text(element, kAXTitleAttribute) ?? "", window.title)
        }
        guard matchingWindows.count == 1, let root = matchingWindows.first else { return ([], false) }
        var pending: [(AXUIElement, CGRect?)] = [(root, nil)]
        var cursor = 0; var regions: [CGRect] = []
        var visited = Set<CFHashCode>()
        while cursor < pending.count, cursor < 1800, Date() < deadline {
            let (element, inheritedSidebar) = pending[cursor]; cursor += 1
            guard visited.insert(CFHash(element)).inserted else { continue }
            let role = text(element, kAXRoleAttribute) ?? ""
            if role == kAXImageRole { continue }
            var sidebar = inheritedSidebar
            if role == "AXWebArea" {
                let url = value(element, kAXURLAttribute).map { String(describing: $0) } ?? ""
                if window.bundle == "org.mozilla.firefox", url == "chrome://browser/content/webext-panels.xhtml" { sidebar = frame(element) }
                else if sidebar == nil { continue }
            }
            let descendants = children(element)
            let labels = sidebar != nil && descendants.isEmpty
                ? [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { text(element, $0) } : []
            let matches = tabs.filter { tab in !tab.title.isEmpty && labels.contains { $0 == tab.title || $0.hasPrefix(tab.title + " - Memory usage - ") } }
            if let sidebar, descendants.isEmpty, !matches.isEmpty, matches.allSatisfy({ selected.contains($0.id) }), let bounds = frame(element) {
                let row = CGRect(x: sidebar.minX + 2, y: bounds.minY - 5, width: sidebar.width - 4, height: bounds.height + 10).intersection(sidebar)
                if FocusBlurPolicy.valid(row) { regions.append(row) }
            }
            if sidebar == nil, role == kAXTabGroupRole {
                var nodes = descendants.reversed().map { ($0, 0) }; var native: [AXUIElement] = []
                while let (node, depth) = nodes.popLast(), Date() < deadline, native.count < 500 {
                    let kind = text(node, kAXRoleAttribute) ?? ""
                    if kind == kAXRadioButtonRole || kind == "AXTab" { native.append(node); continue }
                    if depth < 4, kind != "AXWebArea", kind != kAXImageRole { nodes.append(contentsOf: children(node).reversed().map { ($0, depth + 1) }) }
                }
                let ordered = tabs.sorted { $0.index < $1.index }
                let exactOrder = ordered.count == native.count && ordered.enumerated().allSatisfy { $0.offset == $0.element.index }
                for (index, node) in native.enumerated() {
                    let nodeLabels = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { text(node, $0) }
                    let matching = ordered.filter { tab in !tab.title.isEmpty && nodeLabels.contains { $0 == tab.title || $0.hasPrefix(tab.title + " - Memory usage - ") } }
                    let marked = exactOrder ? selected.contains(ordered[index].id) : (!matching.isEmpty && matching.allSatisfy { selected.contains($0.id) })
                    if marked, let rect = frame(node), FocusBlurPolicy.valid(rect) { regions.append(rect.insetBy(dx: 1, dy: 1)) }
                }
                continue
            }
            pending.append(contentsOf: descendants.prefix(max(0, 1800 - pending.count)).map { ($0, sidebar) })
        }
        return (regions, cursor >= pending.count && Date() < deadline)
    }
}
