import Foundation

/// A finder belongs to the explicitly chosen browser window, never whichever
/// browser/profile happens to be frontmost when a search result arrives.
public struct WebsiteFinderTarget: Equatable, Sendable {
    public var browserBundleIdentifier: String
    public var browserSessionID: String
    public var browserWindowID: Int
    public var anchorTabID: Int
    public var overviewGeneration: UUID

    public init(browserBundleIdentifier: String, browserSessionID: String,
                browserWindowID: Int, anchorTabID: Int, overviewGeneration: UUID) {
        self.browserBundleIdentifier = browserBundleIdentifier
        self.browserSessionID = browserSessionID
        self.browserWindowID = browserWindowID
        self.anchorTabID = anchorTabID
        self.overviewGeneration = overviewGeneration
    }

    public var isValid: Bool {
        ["org.mozilla.firefox", "com.google.Chrome"].contains(browserBundleIdentifier)
            && !browserSessionID.isEmpty && browserSessionID.utf8.count <= 1024
            && browserWindowID >= 0 && anchorTabID >= 0
    }

    public var browserName: String { browserBundleIdentifier == "org.mozilla.firefox" ? "Firefox" : "Chrome" }
}

/// No navigation decision creates a browser tab. The caller separately checks
/// the current browser/window/session and owns the eventual creation receipt.
public enum WebsiteFinderPolicy {
    public enum Submission: Equatable {
        case search(URL)
        case destination(URL)
        case invalid
    }
    public enum Navigation: Equatable {
        case search
        case destination(URL)
        case cancel
    }

    public static func submission(_ input: String) -> Submission {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .invalid }
        let containsWhitespace = value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let lower = value.lowercased()
        let hasWebScheme = lower.hasPrefix("https://") || lower.hasPrefix("http://")
        let bareHost = !containsWhitespace && (value.contains(".") || lower == "localhost" || lower.hasPrefix("localhost:") || value.hasPrefix("["))
        if hasWebScheme { return validatedURL(value).map(Submission.destination) ?? .invalid }
        // Do not send malformed/privileged URL attempts to a search provider.
        if value.contains("://") { return .invalid }
        if value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil {
            let pieces = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let port = pieces.last?.split(separator: "/", maxSplits: 1).first ?? ""
            let host = String(pieces[0]).lowercased()
            guard (host.contains(".") || host == "localhost"), !port.isEmpty,
                  port.allSatisfy(\.isNumber) else { return .invalid }
        }
        if bareHost { return validatedURL("https://" + value).map(Submission.destination) ?? .invalid }
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [.init(name: "q", value: value)]
        return components.url.map(Submission.search) ?? .invalid
    }

    public static func validatedURL(_ value: String) -> URL? {
        guard !value.isEmpty, value.utf8.count <= 8192,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.contains("\\"),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty, host.utf8.count <= 253,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else { return nil }
        return url
    }

    public static func isSearchPage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              ["duckduckgo.com", "html.duckduckgo.com"].contains(url.host?.lowercased() ?? "") else { return false }
        return ["/html", "/html/"].contains(url.path)
    }

    /// Search redirects are decoded only for the exact provider endpoint; an
    /// arbitrary page's `url`/`q` parameter is never mistaken for its destination.
    public static func resultDestination(_ url: URL) -> URL? {
        if ["duckduckgo.com", "html.duckduckgo.com"].contains(url.host?.lowercased() ?? ""),
           ["/l", "/l/"].contains(url.path) {
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
            let candidates = items.filter { $0.name == "uddg" }.compactMap(\.value)
            guard candidates.count == 1 else { return nil }
            return validatedURL(candidates[0])
        }
        return validatedURL(url.absoluteString)
    }

    /// Only an explicit top-level result click captures a destination. External
    /// automatic redirects, frames, downloads and script navigation are denied.
    public static func navigation(to url: URL?, userClickedLink: Bool,
                                  topLevel: Bool, download: Bool) -> Navigation {
        guard topLevel, !download, let url else { return .cancel }
        if isSearchPage(url) { return .search }
        guard userClickedLink, let destination = resultDestination(url), !isSearchPage(destination) else { return .cancel }
        return .destination(destination)
    }
}

/// Single-use capture, including delayed callbacks after cancellation or a
/// browser/profile/window/overview change. This state is shared by direct URL
/// submission and result-click interception.
public struct WebsiteFinderCapture: Sendable {
    public let target: WebsiteFinderTarget
    public private(set) var destination: URL?
    public private(set) var cancelled = false
    public init(target: WebsiteFinderTarget) { self.target = target }
    public mutating func cancel() { cancelled = true }
    public mutating func take(_ url: URL, currentTarget: WebsiteFinderTarget?) -> URL? {
        guard target.isValid, currentTarget == target, !cancelled, destination == nil,
              let valid = WebsiteFinderPolicy.validatedURL(url.absoluteString) else { return nil }
        destination = valid
        return valid
    }
}
