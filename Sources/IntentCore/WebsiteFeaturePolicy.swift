import Foundation

public enum FocusWebsite: String, Codable, CaseIterable, Identifiable {
    case instagram, youtube
    public var id: String { rawValue }
    public var name: String { self == .instagram ? "Instagram" : "YouTube" }
    public static func matching(_ value: String) -> Self? {
        let raw = value.contains("://") ? value : "https://\(value)"
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return nil }
        if host == "instagram.com" || host.hasSuffix(".instagram.com") { return .instagram }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be" { return .youtube }
        return nil
    }
    public var choices: [(id: String, label: String)] {
        switch self {
        case .instagram: [("messages", "Messages"), ("feed", "Feed"), ("reels", "Reels"), ("stories", "Stories"), ("explore", "Explore & profiles")]
        case .youtube: [("search", "Search"), ("feed", "Home feed"), ("shorts", "Shorts"), ("recommendations", "Recommendations"), ("comments", "Comments"), ("autoplay", "Autoplay")]
        }
    }
}

public struct WebsiteFeaturePolicy: Codable, Equatable {
    public var version: Int = 1
    public var allowedFeatures: Set<String>
    public init(site: FocusWebsite) { allowedFeatures = site == .instagram ? ["messages"] : ["search"] }
    public func summary(for site: FocusWebsite) -> String {
        if site == .instagram && allowedFeatures == ["messages"] { return "Messages only" }
        if site == .youtube && allowedFeatures == ["search"] { return "Videos & search only" }
        return "\(allowedFeatures.count + (site == .youtube ? 1 : 0)) allowed features"
    }
    public func isValid(for site: FocusWebsite) -> Bool {
        version == 1 && allowedFeatures.isSubset(of: Set(site.choices.map(\.id)))
            && (site != .instagram || !allowedFeatures.isEmpty)
    }
}
