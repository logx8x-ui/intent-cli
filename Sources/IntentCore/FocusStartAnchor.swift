import Foundation

/// The exact work surface at DBT Run submission, captured before asynchronous
/// browser discovery. A changed destination cancels startup; it is never raised
/// again later to undo the user's newer choice.
public struct FocusStartAnchor: Equatable, Sendable {
    public var nativeWindowID: UInt32
    public var pid: Int32
    public var bundleIdentifier: String
    public var browserWindowID: Int?
    public var browserTabID: Int?
    public var browserSessionID: String?

    public init(nativeWindowID: UInt32, pid: Int32, bundleIdentifier: String,
                browserWindowID: Int? = nil, browserTabID: Int? = nil, browserSessionID: String? = nil) {
        self.nativeWindowID = nativeWindowID; self.pid = pid; self.bundleIdentifier = bundleIdentifier
        self.browserWindowID = browserWindowID; self.browserTabID = browserTabID; self.browserSessionID = browserSessionID
    }

    public var isValid: Bool {
        guard nativeWindowID > 0, pid > 0, !bundleIdentifier.isEmpty else { return false }
        if ["org.mozilla.firefox", "com.google.Chrome"].contains(bundleIdentifier) {
            return browserWindowID.map { $0 >= 0 } == true && browserTabID.map { $0 >= 0 } == true
                && browserSessionID.map { !$0.isEmpty } == true
        }
        return browserWindowID == nil && browserTabID == nil && browserSessionID == nil
    }

    public func matchesNative(windowID: UInt32?, pid: Int32?, bundleIdentifier: String?) -> Bool {
        isValid && windowID == nativeWindowID && pid == self.pid && bundleIdentifier == self.bundleIdentifier
    }

    public func matchesBrowserSnapshot(_ snapshot: BrowserTabSnapshot?) -> Bool {
        guard isValid else { return false }
        guard let browserTabID, let browserWindowID, let browserSessionID else { return true }
        guard let snapshot, snapshot.browserBundleIdentifier == bundleIdentifier,
              snapshot.browserSessionID == browserSessionID else { return false }
        let active = (snapshot.allTabs ?? snapshot.tabs).filter { $0.windowID == browserWindowID && $0.active }
        return active.count == 1 && active[0].id == browserTabID
    }

    public func isPermitted(nativeWindowPermitted: Bool, accessMode: IntentionAccessMode,
                            selectedTabIDs: [Int]?, browserIsUnrestricted: Bool) -> Bool {
        guard isValid, nativeWindowPermitted else { return false }
        guard !browserIsUnrestricted, let browserTabID, let selectedTabIDs, !selectedTabIDs.isEmpty else { return true }
        return accessMode == .whitelist ? selectedTabIDs.contains(browserTabID) : !selectedTabIDs.contains(browserTabID)
    }

    public struct StartupResources: Equatable {
        public var appIDs: Set<String>
        public var windowIDs: [String: Set<UInt32>]
        public var tabIDs: [String: [Int]]?
        public init(appIDs: Set<String>, windowIDs: [String: Set<UInt32>], tabIDs: [String: [Int]]?) {
            self.appIDs = appIDs; self.windowIDs = windowIDs; self.tabIDs = tabIDs
        }
    }

    /// Add As You Go already permits the current work resource. Seed the actual
    /// initial native/browser owners too, so their initial hide pass cannot
    /// displace a destination that preflight just accepted. Never change drafts.
    public func seedingCurrentResources(_ resources: StartupResources, addAsYouGo: Bool,
                                        accessMode: IntentionAccessMode, blockedAppIDs: Set<String>) -> StartupResources {
        guard isValid, addAsYouGo, accessMode == .whitelist, !blockedAppIDs.contains(bundleIdentifier) else { return resources }
        var result = resources
        let wasAllowed = result.appIDs.contains(bundleIdentifier)
        result.appIDs.insert(bundleIdentifier)
        if result.windowIDs[bundleIdentifier] != nil || !wasAllowed {
            result.windowIDs[bundleIdentifier, default: []].insert(nativeWindowID)
        }
        // A browser with no selected-tab scope stays unrestricted. Introducing
        // a new scope here would accidentally narrow an allowed whole browser.
        if let browserTabID, var tabs = result.tabIDs?[bundleIdentifier], !tabs.contains(browserTabID) {
            tabs.append(browserTabID)
            result.tabIDs?[bundleIdentifier] = tabs
        }
        return result
    }
}
