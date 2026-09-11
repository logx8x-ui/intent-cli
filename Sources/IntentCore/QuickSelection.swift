import Foundation

/// Browser tab identifiers are scoped to a browser, never shared between browsers.
public struct QuickSelectionTab: Hashable {
    public var browser: String
    public var id: Int
    public init(browser: String, id: Int) { self.browser = browser; self.id = id }
}

public struct QuickSelection {
    public var accessMode: IntentionAccessMode = .whitelist
    public var apps: Set<String> = []
    public var tabs: Set<QuickSelectionTab> = []
    public init() {}

    public static let browsers: Set<String> = ["org.mozilla.firefox", "com.google.Chrome"]

    public mutating func toggleApp(_ identifier: String, snapshots: [BrowserTabSnapshot]) {
        if apps.remove(identifier) != nil {
            tabs = tabs.filter { $0.browser != identifier }
        } else {
            apps.insert(identifier)
            for tab in (accessMode == .blacklist ? [] : snapshots.first(where: { $0.browserBundleIdentifier == identifier })?.tabs ?? []) {
                if Self.isSelectable(tab) { tabs.insert(.init(browser: identifier, id: tab.id)) }
            }
        }
    }

    public mutating func toggleTab(_ key: QuickSelectionTab) {
        if tabs.remove(key) == nil { tabs.insert(key); apps.insert(key.browser) }
        if !tabs.contains(where: { $0.browser == key.browser }) { apps.remove(key.browser) }
    }

    public mutating func toggleBrowserWindow(browser: String, windowID: Int, snapshots: [BrowserTabSnapshot]) {
        let keys = Set((snapshots.first { $0.browserBundleIdentifier == browser }?.tabs ?? [])
            .filter { $0.windowID == windowID && Self.isSelectable($0) }
            .map { QuickSelectionTab(browser: browser, id: $0.id) })
        guard !keys.isEmpty else { return }
        if keys.isSubset(of: tabs) { tabs.subtract(keys) } else { tabs.formUnion(keys) }
        if tabs.contains(where: { $0.browser == browser }) { apps.insert(browser) }
        else { apps.remove(browser) }
    }

    public static func isSelectable(_ tab: BrowserTabItem) -> Bool {
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
        for browser in apps.intersection(Self.browsers) {
            if accessMode == .blacklist, !tabs.contains(where: { $0.browser == browser }) { continue }
            guard let snapshot = snapshots.first(where: { $0.browserBundleIdentifier == browser }) else {
                throw QuickSelectionError.browserUnavailable
            }
            let selected = snapshot.tabs.filter { tabs.contains(.init(browser: browser, id: $0.id)) }
            guard !selected.isEmpty else { throw QuickSelectionError.chooseTabs }
            for tab in selected {
                guard Self.isSelectable(tab) else { throw QuickSelectionError.changedTabs }
                foundTabs.insert(.init(browser: browser, id: tab.id))
                let site = AllowedWebsite(tab.url, browserBundleIdentifier: browser)
                if !websites.contains(where: { $0.resourceID == site.resourceID }) { websites.append(site) }
            }
        }
        guard foundTabs == tabs else { throw QuickSelectionError.changedTabs }
        var intention = Intention(
            name: accessMode == .blacklist ? "Quick Block" : "Quick Focus", icon: "square.grid.2x2", colorHex: accessMode == .blacklist ? "#FF453A" : "#34C759", folder: "",
            allowedApps: chosen, allowedWebsites: websites,
            startupActions: [], restrictions: .init(),
            restrictionNodes: [.init(kind: .dontStartUp, position: .init(x: 220, y: 170),
                                    excludedResourceIDs: chosen.map(\.resourceID) + websites.map(\.resourceID))]
        )
        intention.accessMode = accessMode
        intention.selectionOnly = true
        return intention
    }

    public var tabIDsByBrowser: [String: [Int]] {
        Dictionary(grouping: tabs, by: \.browser).mapValues { $0.map(\.id).sorted() }
    }
}

public enum QuickSelectionError: LocalizedError {
    case changedApps, changedTabs, browserUnavailable, chooseTabs
    public var errorDescription: String? {
        switch self {
        case .changedApps: "Choose at least one running app. If an app has quit, refresh your selection."
        case .changedTabs: "A selected tab has changed or closed. Review your tabs and try again."
        case .browserUnavailable: "Browser tabs are unavailable. Connect the latest Intent Browser Guard and refresh."
        case .chooseTabs: "Choose at least one website tab for each selected browser."
        }
    }
}
