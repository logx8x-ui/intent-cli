import Foundation
import IntentCore

func runWebsiteFinderSpecs() throws {
    let destination = URL(string: "https://en.wikipedia.org/wiki/Focus")!
    try expect(WebsiteFinderPolicy.submission(destination.absoluteString) == .destination(destination), "A typed website is captured without loading it in the finder")
    try expect(WebsiteFinderPolicy.submission("example.com/path") == .destination(URL(string: "https://example.com/path")!), "Bare hosts default to HTTPS")
    guard case .search(let search) = WebsiteFinderPolicy.submission("Wikipedia focus") else { throw SpecFailure(description: "Website finder must turn ordinary words into a search") }
    try expect(WebsiteFinderPolicy.isSearchPage(search), "Queries use the explicitly identified search provider")
    try expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Wikipedia focus", "Search encoding retains the exact user query")
    for value in ["", "javascript:alert(1)", "file:///tmp/x", "file:///tmp/x.html", "about:config", "https://user:password@example.com", "https://", "https:example.com", "data:text/html,hi", "a\nb", "https://example.com\\@evil.test", "foo://example.com", "https://example.com:70000"] {
        try expect(WebsiteFinderPolicy.submission(value) == .invalid, "Finder rejects blank, unsafe, credential-bearing or malformed destinations: \(value)")
    }
    try expect(WebsiteFinderPolicy.submission("localhost:8080/path") == .destination(URL(string: "https://localhost:8080/path")!), "Explicit bare host ports are not mistaken for URL schemes")
    let encoded = destination.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let redirect = URL(string: "https://duckduckgo.com/l/?uddg=" + encoded)!
    try expect(WebsiteFinderPolicy.navigation(to: redirect, userClickedLink: true, topLevel: true, download: false) == .destination(destination), "A clicked provider redirect is captured before its destination loads")
    try expect(WebsiteFinderPolicy.navigation(to: destination, userClickedLink: false, topLevel: true, download: false) == .cancel, "Automatic outside redirects never add websites")
    try expect(WebsiteFinderPolicy.navigation(to: destination, userClickedLink: true, topLevel: false, download: false) == .cancel, "Embedded frames cannot select a destination")
    try expect(WebsiteFinderPolicy.navigation(to: destination, userClickedLink: true, topLevel: true, download: true) == .cancel, "Download links cannot leave the finder")
    try expect(!WebsiteFinderPolicy.isSearchPage(URL(string: "https://html.duckduckgo.com.evil.test/html/?q=x")!), "Search authority uses exact hosts, never suffix lookalikes")
    try expect(WebsiteFinderPolicy.resultDestination(URL(string: "https://duckduckgo.com/l/?uddg=javascript%3Aalert(1)")!) == nil, "Provider redirects cannot smuggle privileged schemes")
    try expect(WebsiteFinderPolicy.resultDestination(URL(string: "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fa.test&uddg=https%3A%2F%2Fb.test")!) == nil, "Ambiguous duplicated destination parameters fail closed")
    let target = WebsiteFinderTarget(browserBundleIdentifier: "org.mozilla.firefox", browserSessionID: "profile-one", browserWindowID: 42, anchorTabID: 7, overviewGeneration: UUID())
    var capture = WebsiteFinderCapture(target: target)
    var replacement = target; replacement.browserSessionID = "profile-two"
    try expect(capture.take(destination, currentTarget: replacement) == nil, "A late result cannot add to a different browser profile")
    replacement = target; replacement.browserWindowID = 43
    try expect(capture.take(destination, currentTarget: replacement) == nil, "A late result cannot add to a different browser window")
    replacement = target; replacement.overviewGeneration = UUID()
    try expect(capture.take(destination, currentTarget: replacement) == nil, "Closing and reopening overview invalidates the old finder")
    replacement = target; replacement.anchorTabID = 8
    try expect(capture.take(destination, currentTarget: replacement) == nil, "An anchor tab change invalidates the original capture context")
    replacement = target; replacement.browserBundleIdentifier = "com.google.Chrome"
    try expect(capture.take(destination, currentTarget: replacement) == nil, "A Firefox result cannot be reassigned to Chrome")
    try expect(capture.take(destination, currentTarget: nil) == nil, "A missing live target cannot create a tab")
    try expect(capture.take(destination, currentTarget: target) == destination, "The matching finder captures once")
    try expect(capture.take(destination, currentTarget: target) == nil, "Repeated click and enter events cannot create duplicate captures")
    capture = WebsiteFinderCapture(target: target); capture.cancel()
    try expect(capture.take(destination, currentTarget: target) == nil, "Cancelled finders cannot add a late result")
}
