import Foundation
import IntentCore

/// One walker for live AX and deterministic browser-chrome fixtures. The reader
/// owns IPC deadlines and distinguishes an unavailable attribute from a failed
/// query; a failed query cannot certify that an existing mark disappeared.
public struct WorkspaceTabOutlineReader<Element> {
    public var text: (Element, String) -> String?
    public var children: (Element) -> [Element]
    public var frame: (Element) -> CGRect?
    public var key: (Element) -> Int
    public var equal: (Element, Element) -> Bool
    public var hasTime: () -> Bool
    public var readsComplete: () -> Bool
    public init(text: @escaping (Element, String) -> String?, children: @escaping (Element) -> [Element],
                frame: @escaping (Element) -> CGRect?, key: @escaping (Element) -> Int,
                equal: @escaping (Element, Element) -> Bool, hasTime: @escaping () -> Bool,
                readsComplete: @escaping () -> Bool) {
        self.text = text; self.children = children; self.frame = frame
        self.key = key; self.equal = equal; self.hasTime = hasTime; self.readsComplete = readsComplete
    }
}

public struct WorkspaceTabOutlineScan {
    public let regions: [CGRect]
    public let complete: Bool
    public let identityContradiction: Bool
    public init(regions: [CGRect], complete: Bool, identityContradiction: Bool = false) {
        self.regions = regions; self.complete = complete; self.identityContradiction = identityContradiction
    }
    /// Positive identity contradictions invalidate previous coordinates even
    /// when discovered during a partial read. Ordinary IPC timeouts do not.
    public func updateContinuity(_ continuity: inout TabBlurContinuity, context: String, now: Date) -> [CGRect] {
        continuity.update(regions, context: context, complete: complete || identityContradiction, now: now)
    }
}

public enum WorkspaceTabOutlineScanner {
    /// Firefox may omit its current standard window from AXWindows while still
    /// exposing that exact object through AXFocusedWindow/AXMainWindow. Union
    /// those roots before matching; a minimized sibling with the same saved
    /// frame must never stand in for the requested visible window.
    public static func windowRoot<Element>(listed: [Element], focused: Element?, main: Element?,
                                           targetFrame: CGRect, targetTitle: String,
                                           reader: WorkspaceTabOutlineReader<Element>,
                                           isMinimized: (Element) -> Bool) -> Element? {
        var unique: [Element] = []
        for element in listed + [focused, main].compactMap({ $0 }) {
            guard reader.hasTime() else { return nil }
            if !unique.contains(where: { reader.equal($0, element) }) { unique.append(element) }
        }
        let geometryMatches = unique.filter { element in
            guard reader.hasTime(), !isMinimized(element), reader.text(element, "AXRole") == "AXWindow",
                  let rect = reader.frame(element) else { return false }
            return abs(rect.minX - targetFrame.minX) < 3 && abs(rect.minY - targetFrame.minY) < 3
                && abs(rect.width - targetFrame.width) < 3 && abs(rect.height - targetFrame.height) < 3
        }
        // CG and AX titles can change on different ticks after navigation. Keep
        // the existing unique-geometry match, but never guess between overlaps.
        let matches = geometryMatches.count == 1 ? geometryMatches : geometryMatches.filter {
            BrowserWindowMatching.sameWindowTitle(reader.text($0, "AXTitle") ?? "", targetTitle)
        }
        guard reader.hasTime(), matches.count == 1 else { return nil }
        return matches[0]
    }

    private struct Sidebar {
        var bounds: CGRect
        var exactRows = false
        var extensionHost: String? = nil
    }
    public static func scan<Element>(root: Element, browser: String, tabs: [BrowserTabItem], selected: Set<Int>,
                                     reader: WorkspaceTabOutlineReader<Element>, nodeLimit: Int = 1800) -> WorkspaceTabOutlineScan {
        var pending: [(Element, Sidebar?)] = [(root, nil)]
        var cursor = 0, truncated = false
        var recognizedChrome = false
        var regions: [CGRect] = []
        var visited: [Int: [Element]] = [:]
        let tabIDs = Set(tabs.map(\.id))
        let unpinnedIDs = Set(tabs.filter { $0.pinned != true }.map(\.id))
        func rowID(_ identifier: String?) -> Int? {
            guard let identifier, identifier.hasPrefix("tab"), let id = Int(identifier.dropFirst(3)),
                  identifier == "tab\(id)", id >= 0 else { return nil }
            return id
        }
        func labels(_ node: Element) -> [String] {
            ["AXTitle", "AXValue", "AXDescription"].compactMap { reader.text(node, $0) }
        }
        func labelMatches(_ label: String, title: String) -> Bool {
            !title.isEmpty && (label == title || label.hasPrefix(title + " - Memory usage - ")
                || BrowserWindowMatching.sameWindowTitle(label, title))
        }
        func matching(_ labels: [String]) -> [BrowserTabItem] {
            tabs.filter { tab in labels.contains { labelMatches($0, title: tab.title) } }
        }
        func nativeLabel(_ node: Element) -> String? {
            // A radio button's numeric AXValue is its selected state. Chrome
            // commonly puts the actual page title in AXDescription instead;
            // icon-only/pinned tabs may expose only a generic description.
            for attribute in ["AXTitle", "AXValue", "AXDescription"] {
                guard reader.hasTime(), let value = reader.text(node, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { continue }
                if attribute == "AXValue", ["0", "1", "true", "false"].contains(value.lowercased()) { continue }
                if attribute == "AXDescription", ["tab", "pinned tab", "selected tab", "radio button"].contains(value.lowercased()) { continue }
                return value
            }
            return nil
        }
        func valid(_ rect: CGRect) -> Bool {
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
                && rect.width > 5 && rect.height > 5 && rect.width < 16000 && rect.height < 16000
        }
        func enqueue(_ children: [Element], sidebar: Sidebar?) {
            let room = max(0, nodeLimit - pending.count)
            if children.count > room { truncated = true }
            pending.append(contentsOf: children.prefix(room).map { ($0, sidebar) })
        }
        func sidebarTabFrame(_ row: Element, outer: CGRect) -> CGRect {
            // Sidebery's exact-ID row includes its trailing spacing and left
            // indentation. The actual painted tab is a direct, empty group:
            // live AX reports e.g. a 268x38 row with a 268x32 background, or a
            // 254x32 indented background. Use that live child, not a fixed
            // subtraction, text-label width or a rectangle inferred from order.
            let descendants = reader.children(row)
            guard descendants.count <= 24, reader.hasTime() else { return outer }
            var backgrounds: [CGRect] = []
            for child in descendants {
                guard reader.hasTime() else { return outer }
                guard reader.text(child, "AXRole") == "AXGroup",
                      let candidate = reader.frame(child), valid(candidate),
                      candidate.width >= outer.width / 2, candidate.height >= outer.height / 2,
                      abs(candidate.minY - outer.minY) <= 1,
                      abs(candidate.maxX - outer.maxX) <= 1,
                      candidate.minX >= outer.minX - 1, candidate.maxY <= outer.maxY + 1,
                      reader.children(child).isEmpty else { continue }
                if !backgrounds.contains(candidate) { backgrounds.append(candidate) }
            }
            // Old sidebar builds may expose only label/icon children. Preserve
            // their exact row geometry; ambiguous children never choose a new
            // tab or a guessed shape.
            return backgrounds.count == 1 ? backgrounds[0] : outer
        }
        func inconsistentFittingCohort(_ parent: Element, children: [Element]) -> Bool {
            // Firefox can expose a stale scroll offset: every regular Sidebery
            // row is displaced together while its container and pinned strip
            // remain correct. Never manufacture a correction from tab order.
            // This narrow rejection needs the *entire* unpinned snapshot cohort;
            // a clipped subset, collapsed panel or genuinely scrollable list is
            // not evidence of inconsistency.
            guard unpinnedIDs.count >= 2, !unpinnedIDs.isDisjoint(with: selected), children.count >= 2, children.count <= 500,
                  reader.hasTime() else { return false }
            let prefix = children.prefix(3).map { rowID(reader.text($0, "AXDOMIdentifier")) }
            guard prefix.compactMap({ $0 }).filter(unpinnedIDs.contains).count >= 2 else { return false }
            var identities = prefix
            identities.append(contentsOf: children.dropFirst(prefix.count).map { rowID(reader.text($0, "AXDOMIdentifier")) })
            let present = identities.compactMap { $0 }
            guard present.count == unpinnedIDs.count, Set(present) == unpinnedIDs,
                  let container = reader.frame(parent), valid(container), reader.hasTime() else { return false }
            let frames = children.map(reader.frame)
            guard frames.allSatisfy({ $0.map(valid) == true }) else { return false }
            let rowFrames = zip(identities, frames).compactMap { id, frame in id == nil ? nil : frame }
            guard let first = rowFrames.first, let last = rowFrames.last else { return false }
            for (a, b) in zip(rowFrames, rowFrames.dropFirst()) {
                guard abs(a.maxY - b.minY) <= 1, abs(a.minX - b.minX) <= 1, abs(a.width - b.width) <= 1 else { return false }
            }
            let cohort = first.union(last)
            guard cohort.height <= container.height + 1,
                  cohort.minX >= container.minX - 1, cohort.maxX <= container.maxX + 1,
                  frames.allSatisfy({ frame in
                      guard let frame else { return false }
                      return frame.minY >= cohort.minY - 1 && frame.maxY <= cohort.maxY + 1
                          && frame.minX >= container.minX - 1 && frame.maxX <= container.maxX + 1
                  }) else { return false }
            return cohort.minY < container.minY - 1 || cohort.maxY > container.maxY + 1
        }
        while cursor < pending.count, cursor < nodeLimit, reader.hasTime() {
            let (element, inheritedSidebar) = pending[cursor]; cursor += 1
            let key = reader.key(element)
            if visited[key, default: []].contains(where: { reader.equal($0, element) }) { continue }
            visited[key, default: []].append(element)
            guard let role = reader.text(element, "AXRole") else { truncated = true; continue }
            // Decorations are not tab controls and may contain hundreds of SVG nodes.
            if role == "AXImage" { continue }
            var sidebar = inheritedSidebar
            if role == "AXWebArea" {
                let url = reader.text(element, "AXURL") ?? ""
                if browser == "org.mozilla.firefox", url == "chrome://browser/content/webext-panels.xhtml" {
                    if let bounds = reader.frame(element), valid(bounds) { sidebar = Sidebar(bounds: bounds); recognizedChrome = true }
                    else { truncated = true; continue }
                } else if sidebar == nil { continue }
                else if let url = URL(string: url), url.scheme == "moz-extension" {
                    if let host = sidebar?.extensionHost, url.host != host { continue }
                    if url.path == "/sidebar/sidebar.html" {
                        sidebar?.exactRows = true
                        sidebar?.extensionHost = url.host
                        if let previousBounds = sidebar?.bounds, let bounds = reader.frame(element), valid(bounds) {
                            sidebar?.bounds = bounds.intersection(previousBounds)
                        }
                    }
                } else {
                    // A page embedded in an extension sidebar is still page
                    // content, not native browser tabs.
                    continue
                }
            }
            // Sidebery exposes tab identity on the row, including icon-only pinned
            // tabs. A title leaf is neither a row nor an identity: hover previews
            // duplicate it, and separate tabs can have the same title.
            if let sidebar, sidebar.exactRows,
               let id = rowID(reader.text(element, "AXDOMIdentifier")) {
                if tabIDs.contains(id), selected.contains(id) {
                    if let frame = reader.frame(element), valid(frame) {
                        let clipped = sidebarTabFrame(element, outer: frame).intersection(sidebar.bounds)
                        if valid(clipped) { regions.append(clipped.insetBy(dx: 1, dy: 1)) }
                    } else { truncated = true }
                }
                // Never let a known row fall back to ambiguous descendant titles.
                continue
            }
            let descendants = reader.children(element)
            if sidebar?.exactRows == true, inconsistentFittingCohort(element, children: descendants) {
                truncated = true
                continue
            }
            if let sidebar, !sidebar.exactRows, descendants.isEmpty {
                let matches = matching(labels(element))
                if !matches.isEmpty, matches.allSatisfy({ selected.contains($0.id) }), let bounds = reader.frame(element) {
                    let row = CGRect(x: sidebar.bounds.minX + 2, y: bounds.minY - 5,
                                     width: sidebar.bounds.width - 4, height: bounds.height + 10).intersection(sidebar.bounds)
                    if valid(row) { regions.append(row) }
                }
            }
            if sidebar == nil, role == "AXTabGroup" {
                recognizedChrome = true
                var nodes = descendants.reversed().map { ($0, 0) }
                var native: [Element] = [], inspected = 0
                while !nodes.isEmpty, reader.hasTime(), inspected < 500 {
                    let (node, depth) = nodes.removeLast()
                    inspected += 1
                    let kind = reader.text(node, "AXRole") ?? ""
                    if kind == "AXRadioButton" || kind == "AXTab" { native.append(node); continue }
                    if depth < 4, kind != "AXWebArea", kind != "AXImage" {
                        nodes.append(contentsOf: reader.children(node).reversed().map { ($0, depth + 1) })
                    } else if depth >= 4, kind != "AXWebArea", kind != "AXImage", !reader.children(node).isEmpty {
                        truncated = true
                    }
                }
                if !nodes.isEmpty || !reader.hasTime() { truncated = true }
                let ordered = tabs.sorted { $0.index < $1.index }
                let exactOrder = !truncated && reader.readsComplete() && ordered.count == native.count && ordered.enumerated().allSatisfy { $0.offset == $0.element.index }
                if exactOrder {
                    let nativeLabels = native.map(nativeLabel)
                    guard reader.hasTime(), reader.readsComplete() else { truncated = true; continue }
                    // A drag/reorder can happen after the discovery receipt but
                    // before AX traversal. Equal counts and contiguous indices
                    // do not certify order. Contradictory available identities
                    // reject this whole snapshot; never paint by stale index or
                    // fall back to unique titles using that inconsistent cohort.
                    if zip(nativeLabels, ordered).contains(where: { label, tab in
                        label.map { !labelMatches($0, title: tab.title) } ?? false
                    }) { return .init(regions: [], complete: false, identityContradiction: true) }
                }
                for (index, node) in native.enumerated() {
                    let matches = exactOrder ? [ordered[index]] : matching(labels(node))
                    if !matches.isEmpty, matches.allSatisfy({ selected.contains($0.id) }),
                       let rect = reader.frame(node), valid(rect) { regions.append(rect.insetBy(dx: 1, dy: 1)) }
                }
                continue
            }
            enqueue(descendants, sidebar: sidebar)
        }
        return .init(regions: regions, complete: recognizedChrome && !truncated && cursor >= pending.count && reader.hasTime() && reader.readsComplete())
    }
}
