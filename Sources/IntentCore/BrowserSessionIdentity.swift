import Foundation

extension ActiveBrowserRules {
    /// Integer tab IDs may be recycled after a browser restart. Native masks and
    /// click guards must validate the same session identity as Browser Guard.
    public func matchesBrowserSession(_ snapshot: BrowserTabSnapshot) -> Bool {
        let browser = snapshot.browserBundleIdentifier
        guard selectedTabIDsByBrowser?[browser] != nil else { return true }
        guard let expected = selectedBrowserSessionIDsByBrowser?[browser], !expected.isEmpty else { return false }
        return snapshot.browserSessionID == expected
    }
}
