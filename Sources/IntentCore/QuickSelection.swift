import Foundation

/// Browser tab identifiers are scoped to a browser, never shared between browsers.
public struct QuickSelectionTab: Hashable {
    public var browser: String
    public var id: Int
    public init(browser: String, id: Int) { self.browser = browser; self.id = id }
}

public struct QuickSelectionBrowserWindow: Hashable {
    public var browser: String
    public var id: Int
    public init(browser: String, id: Int) { self.browser = browser; self.id = id }
}

public struct QuickSelection {
    /// Visual scope only. Enforcement still uses the exact selected tab IDs.
    public private(set) var browserSessionIDs: [String: String] = [:]
    public var browserWindowTabs: [QuickSelectionBrowserWindow: Set<Int>] = [:]
    private struct RangeState {
        var anchor: Int
        var independent: Set<QuickSelectionTab>
        var range: Set<QuickSelectionTab> = []
    }
    private var ranges: [QuickSelectionBrowserWindow: RangeState] = [:]
    public var accessMode: IntentionAccessMode = .whitelist
    public var apps: Set<String> = []
    public var tabs: Set<QuickSelectionTab> = []
    public var windowIDsByApp: [String: Set<UInt32>] = [:]
    public mutating func toggleWindow(_ id: UInt32, app: String) {
        var ids = windowIDsByApp[app] ?? []
        if ids.remove(id) == nil { ids.insert(id) }
        if ids.isEmpty { windowIDsByApp.removeValue(forKey: app); apps.remove(app) }
        else { windowIDsByApp[app] = ids; apps.insert(app) }
    }
    public var restrictionNodes: [RestrictionNode] = []
    public var frictionNodes: [FrictionNode] = []
    public static let startupSuppressionID = "quick-selection-current-session-startup"
    public init() {}

    public mutating func clearTargets() {
        apps.removeAll(); tabs.removeAll(); windowIDsByApp.removeAll()
        browserWindowTabs.removeAll(); ranges.removeAll(); browserSessionIDs.removeAll()
    }

    public static let browsers: Set<String> = ["org.mozilla.firefox", "com.google.Chrome"]

    @discardableResult
    public mutating func pinBrowserSession(_ browser: String, sessionID: String?) -> Bool {
        guard let sessionID, !sessionID.isEmpty else { return false }
        if tabs.contains(where: { $0.browser == browser }), let pinned = browserSessionIDs[browser], pinned != sessionID { return false }
        browserSessionIDs[browser] = sessionID
        return true
    }

    public mutating func toggleApp(_ identifier: String, snapshots: [BrowserTabSnapshot]) {
        ranges = ranges.filter { $0.key.browser != identifier }
        browserWindowTabs = browserWindowTabs.filter { $0.key.browser != identifier }
        windowIDsByApp.removeValue(forKey: identifier)
        if apps.remove(identifier) != nil {
            tabs = tabs.filter { $0.browser != identifier }
        } else {
            if Self.browsers.contains(identifier), accessMode == .whitelist,
               !pinBrowserSession(identifier, sessionID: snapshots.first { $0.browserBundleIdentifier == identifier }?.browserSessionID) { return }
            apps.insert(identifier)
            for tab in (accessMode == .blacklist ? [] : snapshots.first(where: { $0.browserBundleIdentifier == identifier }).map { $0.allTabs ?? $0.tabs } ?? []) {
                if Self.isSelectable(tab) { tabs.insert(.init(browser: identifier, id: tab.id)) }
            }
        }
    }

    public mutating func toggleTab(_ key: QuickSelectionTab, browserSessionID: String? = nil) {
        if let browserSessionID, !pinBrowserSession(key.browser, sessionID: browserSessionID) { return }
        ranges = ranges.filter { $0.key.browser != key.browser }
        browserWindowTabs = browserWindowTabs.filter { $0.key.browser != key.browser || !$0.value.contains(key.id) }
        if tabs.remove(key) == nil { tabs.insert(key); apps.insert(key.browser) }
        if !tabs.contains(where: { $0.browser == key.browser }) { apps.remove(key.browser) }
    }

    /// Ordinary row clicks remain additive. Shift replaces only the prior range,
    /// preserving selections made independently before the anchor click.
    public mutating func selectTab(_ key: QuickSelectionTab, windowID: Int, displayedTabs: [BrowserTabItem], extendingRange: Bool) {
        let list = QuickSelectionBrowserWindow(browser: key.browser, id: windowID)
        let ordered = displayedTabs.filter { $0.windowID == windowID && Self.isSelectable($0) }.map(\.id)
        guard let end = ordered.firstIndex(of: key.id) else { return }
        if extendingRange, var state = ranges[list], let start = ordered.firstIndex(of: state.anchor) {
            let next = Set(ordered[min(start, end)...max(start, end)].map { QuickSelectionTab(browser: key.browser, id: $0) })
            tabs.subtract(state.range.subtracting(state.independent))
            tabs.formUnion(next)
            state.range = next
            ranges[list] = state
            browserWindowTabs.removeValue(forKey: list)
            updateBrowserMembership(key.browser)
        } else {
            // A disappearing/filtered anchor starts a new gesture; it never borrows
            // a different row at the old index or a tab in another browser window.
            toggleTab(key)
            ranges[list] = RangeState(anchor: key.id, independent: tabs)
        }
    }

    /// Native Shift-click selection is exposed by the browser's highlighted flag.
    /// Use the entire native group only in the target window. Older bridges must
    /// report failure so the UI can request an update, never imply partial success.
    @discardableResult
    public mutating func toggleNativeTabGroup(browser: String, windowID: Int, snapshot: BrowserTabSnapshot) -> Bool {
        guard pinBrowserSession(browser, sessionID: snapshot.browserSessionID) else { return false }
        let windowTabs = (snapshot.allTabs ?? snapshot.tabs).filter { $0.windowID == windowID && Self.isSelectable($0) }
        guard !windowTabs.isEmpty, windowTabs.allSatisfy({ $0.highlighted != nil }) else { return false }
        let highlighted = windowTabs.filter { $0.highlighted == true }
        guard highlighted.contains(where: \.active) else { return false }
        toggleTabGroup(Set(highlighted.map { QuickSelectionTab(browser: browser, id: $0.id) }), browser: browser)
        return true
    }

    private mutating func toggleTabGroup(_ keys: Set<QuickSelectionTab>, browser: String) {
        guard !keys.isEmpty else { return }
        ranges = ranges.filter { $0.key.browser != browser }
        browserWindowTabs = browserWindowTabs.filter { $0.key.browser != browser || $0.value.isDisjoint(with: keys.map(\.id)) }
        if keys.isSubset(of: tabs) { tabs.subtract(keys) }
        else { tabs.formUnion(keys) }
        updateBrowserMembership(browser)
    }

    private mutating func updateBrowserMembership(_ browser: String) {
        if tabs.contains(where: { $0.browser == browser }) { apps.insert(browser) }
        else { apps.remove(browser) }
    }

    public mutating func toggleBrowserWindow(browser: String, windowID: Int, snapshots: [BrowserTabSnapshot], outlineWholeWindow: Bool = false) {
        guard pinBrowserSession(browser, sessionID: snapshots.first { $0.browserBundleIdentifier == browser }?.browserSessionID) else { return }
        let keys = Set((snapshots.first { $0.browserBundleIdentifier == browser }.map { $0.allTabs ?? $0.tabs } ?? [])
            .filter { $0.windowID == windowID && Self.isSelectable($0) }
            .map { QuickSelectionTab(browser: browser, id: $0.id) })
        guard !keys.isEmpty else { return }
        let windowKey = QuickSelectionBrowserWindow(browser: browser, id: windowID)
        ranges.removeValue(forKey: windowKey)
        browserWindowTabs.removeValue(forKey: windowKey)
        if keys.isSubset(of: tabs) { tabs.subtract(keys) }
        else {
            tabs.formUnion(keys)
            if outlineWholeWindow { browserWindowTabs[windowKey] = Set(keys.map(\.id)) }
        }
        if tabs.contains(where: { $0.browser == browser }) { apps.insert(browser) }
        else { apps.remove(browser) }
    }

    public static func isSelectable(_ tab: BrowserTabItem) -> Bool {
        // Selection is a browser identity operation, not content-script access.
        tab.id >= 0 && tab.windowID >= 0
    }

    public static func hasWebURL(_ tab: BrowserTabItem) -> Bool {
        guard let url = URL(string: tab.url), let scheme = url.scheme?.lowercased() else { return false }
        return ["https", "http"].contains(scheme) && url.host != nil
    }

    public func makeIntention(apps availableApps: [AllowedApp], snapshots: [BrowserTabSnapshot]) throws -> Intention {
        let chosen = availableApps.filter { apps.contains($0.bundleIdentifier) }
        guard !chosen.isEmpty, Set(chosen.map(\.bundleIdentifier)) == apps else {
            throw QuickSelectionError.changedApps
        }
        var websites: [AllowedWebsite] = []
        var foundTabs: Set<QuickSelectionTab> = []
        var requiresTabReselection = false
        for browser in apps.intersection(Self.browsers) {
            if accessMode == .blacklist, !tabs.contains(where: { $0.browser == browser }) { continue }
            guard let snapshot = snapshots.first(where: { $0.browserBundleIdentifier == browser }) else {
                throw QuickSelectionError.browserUnavailable
            }
            guard let pinned = browserSessionIDs[browser], snapshot.browserSessionID == pinned else {
                throw QuickSelectionError.browserSessionChanged
            }
            let selected = (snapshot.allTabs ?? snapshot.tabs).filter { tabs.contains(.init(browser: browser, id: $0.id)) }
            guard !selected.isEmpty else { throw QuickSelectionError.chooseTabs }
            for tab in selected {
                guard Self.isSelectable(tab) else { throw QuickSelectionError.changedTabs }
                foundTabs.insert(.init(browser: browser, id: tab.id))
                if !Self.hasWebURL(tab) { requiresTabReselection = true }
                // URL resources are optional replay metadata. Live policy always
                // uses tabIDsByBrowser, including blank/internal/file/PDF tabs.
                if Self.hasWebURL(tab) {
                    let site = AllowedWebsite(tab.url, browserBundleIdentifier: browser)
                    if !websites.contains(where: { $0.resourceID == site.resourceID }) { websites.append(site) }
                }
            }
        }
        guard foundTabs == tabs else { throw QuickSelectionError.changedTabs }
        let sessionFrictions = frictionNodes.compactMap { node -> FrictionNode? in
            guard case .taskChecklist(let tasks) = node.friction else { return nil }
            var result = node
            result.friction = .taskChecklist(tasks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            return result
        }
        for node in sessionFrictions {
            switch node.friction {
            case .typedPhrase(let text), .reasonPrompt(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw QuickSelectionError.emptyFriction }
            case .taskChecklist(let tasks):
                guard !tasks.isEmpty, tasks.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw QuickSelectionError.emptyFriction }
            default: break
            }
        }
        let resources = chosen.map(\.resourceID) + websites.map(\.resourceID)
        var configuredRestrictions = restrictionNodes
        // Explicit Don't start up choices survive saving; the automatic node below
        // only suppresses duplicate launches for this already-running selection.
        for index in configuredRestrictions.indices where configuredRestrictions[index].kind == .dontStartUp {
            configuredRestrictions[index].excludedResourceIDs = resources
        }
        var intention = Intention(
            name: accessMode == .blacklist ? "Quick Block" : "Quick Focus", icon: "square.grid.2x2", colorHex: accessMode == .blacklist ? "#FF453A" : "#34C759", folder: "",
            allowedApps: chosen, allowedWebsites: websites,
            startupActions: [], restrictions: .init(),
            restrictionNodes: configuredRestrictions + [.init(id: Self.startupSuppressionID, kind: .dontStartUp, position: .init(x: 220, y: 170),
                                    excludedResourceIDs: resources)],
            frictionNodes: sessionFrictions
        )
        intention.accessMode = accessMode
        intention.selectionOnly = true
        intention.selectionBrowserBundleIdentifiers = Array(Set(tabs.map(\.browser))).sorted()
        intention.selectionRequiresTabReselection = requiresTabReselection
        return intention
    }

    public var tabIDsByBrowser: [String: [Int]] {
        Dictionary(grouping: tabs, by: \.browser).mapValues { $0.map(\.id).sorted() }
    }
}

public enum QuickSelectionError: LocalizedError {
    case changedApps, changedTabs, browserUnavailable, browserSessionChanged, chooseTabs, emptyFriction
    public var errorDescription: String? {
        switch self {
        case .changedApps: "Choose at least one running app. If an app has quit, refresh your selection."
        case .changedTabs: "A selected tab has changed or closed. Review your tabs and try again."
        case .browserSessionChanged: "The browser restarted or its connection changed. Clear the selection and choose your tabs again."
        case .browserUnavailable: "Browser tabs are unavailable. Connect the latest Intent Browser Guard and refresh."
        case .chooseTabs: "Choose at least one tab for each selected browser."
        case .emptyFriction: "Add the phrase, prompt, or checklist text before starting."
        }
    }
}
