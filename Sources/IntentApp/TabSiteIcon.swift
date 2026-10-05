import AppKit
import ImageIO
import SwiftUI

/// Browser-provided icons only. No favicon-discovery service, browsing history
/// on disk, cookies, or website request is invented when a snapshot omits one.
@MainActor
final class TabSiteIconStore {
    static let shared = TabSiteIconStore()
    static let maximumBytes = 1_000_000
    private let capacity: Int
    private let fetch: @MainActor (URL) async -> Data?
    private var icons: [String: NSImage] = [:]
    private var recentURLs: [String] = []
    private var remembered: [String: NSImage] = [:]
    private var recentTabs: [String] = []
    private var requestedSources: [String: String] = [:]
    private var recentRequests: [String] = []
    private var failures: [String: Date] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init(capacity: Int = 256, fetch: (@MainActor (URL) async -> Data?)? = nil) {
        self.capacity = max(1, capacity)
        self.fetch = fetch ?? { address in await Self.fetchIcon(address) }
    }

    static func pageScope(_ pageURL: String) -> String {
        guard let parts = URLComponents(string: pageURL),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased() else { return pageURL }
        return "\(scheme)://\(host):\(parts.port ?? (scheme == "https" ? 443 : 80))"
    }

    private func tabKey(identity: String, pageURL: String) -> String {
        identity + "\u{0}" + Self.pageScope(pageURL)
    }

    func cached(url: String?, pageURL: String, identity: String) -> NSImage? {
        let key = tabKey(identity: identity, pageURL: pageURL)
        if let url, !url.isEmpty {
            requestedSources[key] = url
            touch(key, in: &recentRequests)
            while recentRequests.count > capacity { requestedSources.removeValue(forKey: recentRequests.removeFirst()) }
        }
        if let url, let icon = icons[url] {
            touch(url, in: &recentURLs)
            remember(icon, identity: identity, pageURL: pageURL)
            return icon
        }
        if let image = remembered[key] {
            touch(key, in: &recentTabs)
            return image
        }
        return nil
    }

    func load(url: String?, pageURL: String, identity: String) async -> NSImage? {
        let fallback = cached(url: url, pageURL: pageURL, identity: identity)
        guard let url, !url.isEmpty, let address = URL(string: url),
              ["data", "https", "http"].contains(address.scheme?.lowercased() ?? "") else { return fallback }
        if let icon = icons[url] { return icon }
        // A broken URL must not create a retry storm as rows enter/leave the
        // lazy list. A later picker opening may retry after this short cooldown.
        if let failedAt = failures[url], Date().timeIntervalSince(failedAt) < 20 { return fallback }
        let request: Task<Data?, Never>
        if let pending = inFlight[url] { request = pending }
        else {
            let fetch = self.fetch
            request = Task { @MainActor in
                if address.scheme?.lowercased() == "data" { return Self.dataURI(url) }
                return await fetch(address)
            }
            inFlight[url] = request
        }
        // Row disappearance must not cancel a shared request needed by another
        // row. Cache its result even when this particular view has disappeared.
        let data = await request.value
        inFlight.removeValue(forKey: url)
        // Only Sendable bytes cross the Task boundary. AppKit decoding and
        // images stay on the main actor. The first resumed waiter decodes;
        // subsequent waiters reuse that exact cached image without more work.
        let image = icons[url] ?? data.flatMap(Self.decode)
        if let image {
            failures.removeValue(forKey: url)
            icons[url] = image
            touch(url, in: &recentURLs)
            while recentURLs.count > capacity { icons.removeValue(forKey: recentURLs.removeFirst()) }
            // A previous row task may finish after a newer icon source. Cache
            // the URL, but never let that late response replace this tab's newer
            // remembered icon. An omitted URL is not a new source request.
            if requestedSources[tabKey(identity: identity, pageURL: pageURL)] == url {
                remember(image, identity: identity, pageURL: pageURL)
            }
            return image
        }
        failures[url] = Date()
        if failures.count > capacity, let oldest = failures.min(by: { $0.value < $1.value })?.key {
            failures.removeValue(forKey: oldest)
        }
        return fallback
    }

    private func remember(_ image: NSImage, identity: String, pageURL: String) {
        let key = tabKey(identity: identity, pageURL: pageURL)
        remembered[key] = image
        touch(key, in: &recentTabs)
        while recentTabs.count > capacity { remembered.removeValue(forKey: recentTabs.removeFirst()) }
    }

    private func touch(_ key: String, in list: inout [String]) {
        list.removeAll { $0 == key }
        list.append(key)
    }

    static func dataURI(_ source: String) -> Data? {
        guard source.utf8.count <= maximumBytes * 3,
              source.lowercased().hasPrefix("data:image/"), let comma = source.firstIndex(of: ",") else { return nil }
        let metadata = source[..<comma].lowercased()
        let payload = String(source[source.index(after: comma)...])
        let data: Data?
        if metadata.split(separator: ";").contains("base64") {
            data = Data(base64Encoded: payload.removingPercentEncoding ?? payload)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, !data.isEmpty, data.count <= maximumBytes else { return nil }
        return data
    }

    static func decode(_ data: Data) -> NSImage? {
        guard !data.isEmpty, data.count <= maximumBytes else { return nil }
        let text = SVGRootPaint.unicodeText(data)
        if let text,
           text.localizedCaseInsensitiveContains("<!DOCTYPE") || text.localizedCaseInsensitiveContains("<!ENTITY") { return nil }
        let svg = text.flatMap(SVGRootPaint.forDarkPicker)
        let prepared = svg ?? data
        if let source = CGImageSourceCreateWithData(prepared as CFData, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 64,
               kCGImageSourceCreateThumbnailWithTransform: true
           ] as CFDictionary), hasVisiblePixels(thumbnail) {
            return NSImage(cgImage: thumbnail, size: .init(width: 18, height: 18))
        }
        // Only a parsed, normalized UTF-8 SVG may reach the vector fallback.
        // Unknown bytes/encodings must not bypass the XML safety boundary.
        guard let svg, let vector = NSImage(data: svg), vector.isValid,
              vector.size.width > 0, vector.size.height > 0,
              vector.size.width <= 8192, vector.size.height <= 8192 else { return nil }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(.init(x: 0, y: 0, width: 64, height: 64))
        vector.draw(in: .init(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        guard let rendered = bitmap.cgImage, hasVisiblePixels(rendered) else { return nil }
        return NSImage(cgImage: rendered, size: .init(width: 18, height: 18))
    }

    static func hasVisiblePixels(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 64, height <= 64 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: .init(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered && stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 8 }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 0)
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration)
    }()

    private static func fetchIcon(_ address: URL) async -> Data? {
        do {
            let (bytes, response) = try await session.bytes(from: address)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  response.expectedContentLength <= Int64(maximumBytes) else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes, !Task.isCancelled else { return nil }
                data.append(byte)
            }
            return data
        } catch { return nil }
    }
}

/// AppKit can accept an SVG while ignoring its root CSS, leaving `fill="none"`
/// completely transparent. Resolve only scalar root paint and the dark colour
/// scheme used by our picker. This is not a general CSS or web renderer.
private enum SVGRootPaint {
    static func unicodeText(_ data: Data) -> String? {
        let first = Array(data.prefix(4))
        let encoding: String.Encoding
        if data.starts(with: [0xFF, 0xFE, 0, 0]) || (first.count == 4 && first[1...3].allSatisfy { $0 == 0 }) {
            encoding = .utf32LittleEndian
        } else if data.starts(with: [0, 0, 0xFE, 0xFF]) || (first.count == 4 && first[0...2].allSatisfy { $0 == 0 }) {
            encoding = .utf32BigEndian
        } else if data.starts(with: [0xFF, 0xFE]) || (first.count == 4 && first[1] == 0 && first[3] == 0) {
            encoding = .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]) || (first.count == 4 && first[0] == 0 && first[2] == 0) {
            encoding = .utf16BigEndian
        } else {
            encoding = .utf8
        }
        return String(data: data, encoding: encoding)
    }

    static func forDarkPicker(_ text: String) -> Data? {
        var source = text
        if source.first == "\u{FEFF}" { source.removeFirst() }
        // The normalized bytes are UTF-8, so never retain an old UTF-16/32
        // encoding declaration. SVG icons do not need an XML declaration.
        source = source.replacingOccurrences(of: #"^\s*<\?xml\s[^?]*\?>"#, with: "", options: .regularExpression)
        guard source.utf8.count <= TabSiteIconStore.maximumBytes, source.contains("<svg"),
              !source.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !source.localizedCaseInsensitiveContains("<!ENTITY"),
              let data = source.data(using: .utf8),
              let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let root = document.rootElement(), root.localName == "svg" else { return nil }
        var paint: [String: String] = [:]
        func declarations(_ text: String) {
            for declaration in text.split(separator: ";") {
                let pieces = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard pieces.count == 2, ["fill", "stroke", "color"].contains(pieces[0]) else { continue }
                let value = pieces[1].replacingOccurrences(of: #"\s*!important\s*$"#, with: "", options: .regularExpression)
                // Deliberately excludes url(), var(), expressions and external
                // resources. Unsupported paint keeps its normal globe fallback.
                guard value.range(of: #"^(?:#[0-9a-fA-F]{3,8}|[a-zA-Z]+|(?:rgb|rgba|hsl|hsla)\([0-9.% ,+\-]+\))$"#,
                                  options: .regularExpression) != nil else { continue }
                paint[pieces[0]] = value
            }
        }
        func rules(_ stylesheet: String, depth: Int = 0) {
            guard depth < 4, stylesheet.utf8.count <= 65_536 else { return }
            var remaining = stylesheet[...]
            while let opening = remaining.firstIndex(of: "{") {
                let selector = remaining[..<opening].trimmingCharacters(in: .whitespacesAndNewlines)
                var braces = 1
                var cursor = remaining.index(after: opening)
                let bodyStart = cursor
                while cursor < remaining.endIndex {
                    if remaining[cursor] == "{" { braces += 1 }
                    if remaining[cursor] == "}" { braces -= 1 }
                    if braces == 0 { break }
                    cursor = remaining.index(after: cursor)
                }
                guard braces == 0 else { return }
                let body = String(remaining[bodyStart..<cursor])
                if selector == ":root" || selector == "svg" { declarations(body) }
                else if selector.range(of: #"^@media\s*\(\s*prefers-color-scheme\s*:\s*dark\s*\)$"#,
                                       options: .regularExpression) != nil { rules(body, depth: depth + 1) }
                remaining = remaining[remaining.index(after: cursor)...]
            }
        }
        for style in root.elements(forName: "style") {
            let text = (style.stringValue ?? "").replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: "", options: .regularExpression)
            rules(text)
        }
        // Inline root declarations outrank the supported stylesheet rules.
        if let inline = root.attribute(forName: "style")?.stringValue { declarations(inline) }
        guard !paint.isEmpty else { return data }
        for (name, value) in paint {
            if let attribute = root.attribute(forName: name) { attribute.stringValue = value }
            else { root.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
        }
        return document.xmlData
    }
}

@MainActor
struct TabSiteIcon: View {
    let url: String?
    let pageURL: String
    /// Includes browser + browser session + tab ID; IDs can be reused at restart.
    let identity: String
    @State private var icon: NSImage?
    @State private var displayedIdentity: String?

    private var pageIdentity: String { identity + "\u{0}" + TabSiteIconStore.pageScope(pageURL) }
    private var requestIdentity: String { pageIdentity + "\u{0}" + (url ?? "") }

    var body: some View {
        Group {
            if let image = displayedIdentity == pageIdentity ? icon : nil {
                Image(nsImage: image).resizable().scaledToFit()
            } else { Image(systemName: "globe").foregroundStyle(.secondary) }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
        .task(id: requestIdentity) {
            let expected = pageIdentity
            // Never flash a previously loaded icon back to a blank placeholder
            // because the picker re-rendered or the browser is mid-navigation.
            icon = TabSiteIconStore.shared.cached(url: url, pageURL: pageURL, identity: identity)
            displayedIdentity = expected
            let loaded = await TabSiteIconStore.shared.load(url: url, pageURL: pageURL, identity: identity)
            guard !Task.isCancelled, expected == pageIdentity else { return }
            icon = loaded
        }
    }
}
