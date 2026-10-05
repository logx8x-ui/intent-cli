import AppKit

/// Exercises the production cache with injected bytes, never remote browsing or
/// daily data. The main run loop is pumped only inside the isolated QA process.
@MainActor
enum TabSiteIconChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<2 { for x in 0..<2 {
            let offset = y * bitmap.bytesPerRow + x * 4
            bitmap.bitmapData![offset] = 0; bitmap.bitmapData![offset + 1] = 190
            bitmap.bitmapData![offset + 2] = 90; bitmap.bitmapData![offset + 3] = 255
        } }
        let bytes = bitmap.representation(using: .png, properties: [:])!
        try check(TabSiteIconStore.decode(bytes) != nil, "Actual favicon image bytes decode into a bounded display image")
        try check(TabSiteIconStore.decode(Data("not an image".utf8)) == nil,
            "An invalid successful response cannot replace the fallback with an empty image")
        let rootCSSIcon = Data(#"""
            <svg xmlns="http://www.w3.org/2000/svg" width="180" height="180" viewBox="0 0 180 180" fill="none">
              <style>:root { fill: #000; } @media (prefers-color-scheme: dark) { :root { fill: #fff; } }</style>
              <path d="M20 20H160V160H20Z"/>
            </svg>
            """#.utf8)
        let rootCSSImage = TabSiteIconStore.decode(rootCSSIcon)
        let rootCSSBitmap = rootCSSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil).map { NSBitmapImageRep(cgImage: $0) }
        let middle = rootCSSBitmap.flatMap { $0.colorAt(x: $0.pixelsWide / 2, y: $0.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) }
        try check(middle.map { $0.alphaComponent > 0.9 && $0.redComponent > 0.9 && $0.greenComponent > 0.9 && $0.blueComponent > 0.9 } == true,
            "A real root-fill-none plus root-CSS/media SVG structure renders visible white paint in the dark picker")
        let transparentSVG = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" fill="none"><path d="M1 1H17V17H1Z"/></svg>"#.utf8)
        try check(TabSiteIconStore.decode(transparentSVG) == nil,
            "Accepted but fully transparent SVGs retain the globe fallback rather than showing an empty icon")
        try check(TabSiteIconStore.decode(Data(#"<!DOCTYPE svg SYSTEM "https://example.invalid/external.dtd"><svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)) == nil,
            "SVG DTDs and external entities never reach either the XML or native image reader")
        let encodings: [(String.Encoding, String, [UInt8])] = [
            (.utf16LittleEndian, "UTF-16", [0xFF, 0xFE]),
            (.utf16BigEndian, "UTF-16", [0xFE, 0xFF]),
            (.utf32LittleEndian, "UTF-32", [0xFF, 0xFE, 0, 0]),
            (.utf32BigEndian, "UTF-32", [0, 0, 0xFE, 0xFF])
        ]
        for (encoding, declaration, bom) in encodings {
            let header = "<?xml version=\"1.0\" encoding=\"\(declaration)\"?>"
            let visible = header + ##"<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18"><path fill="#fff" d="M1 1H17V17H1Z"/></svg>"##
            let forbidden = header + ##"<!DOCTYPE svg [<!ENTITY paint "#fff">]><svg xmlns="http://www.w3.org/2000/svg" width="18" height="18"><path fill="&paint;" d="M1 1H17V17H1Z"/></svg>"##
            for prefix in [Data(), Data(bom)] {
                try check(TabSiteIconStore.decode(prefix + visible.data(using: encoding)!) != nil,
                    "Unicode SVG encoding \(encoding.rawValue) normalizes its declaration safely, with or without a BOM")
                try check(TabSiteIconStore.decode(prefix + forbidden.data(using: encoding)!) == nil,
                    "Unicode SVG encoding \(encoding.rawValue) cannot bypass DTD/entity rejection, with or without a BOM")
            }
        }
        try check(TabSiteIconStore.decode(Data(##"<!ENTITY paint "#fff"><svg xmlns="http://www.w3.org/2000/svg"/>"##.utf8)) == nil,
            "Standalone entity declarations are rejected independently of DOCTYPE")
        let transparentPNG = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        transparentPNG.bitmapData!.initialize(repeating: 0, count: transparentPNG.bytesPerRow * transparentPNG.pixelsHigh)
        try check(TabSiteIconStore.decode(transparentPNG.representation(using: .png, properties: [:])!) == nil,
            "Transparent raster icons also cannot replace the visible fallback")
        try check(TabSiteIconStore.dataURI("data:image/png;base64," + bytes.base64EncodedString()) == bytes,
            "Browser base64 image data URIs decode correctly")
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><path/></svg>"
        let encoded = svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        try check(TabSiteIconStore.dataURI("data:image/svg+xml," + encoded) == Data(svg.utf8),
            "Percent-encoded SVG favicon data is supported instead of being treated as base64")
        try check(TabSiteIconStore.dataURI("data:text/html;base64," + bytes.base64EncodedString()) == nil
            && TabSiteIconStore.dataURI("data:image/png;base64,invalid") == nil,
            "Malformed and non-image data URIs are rejected")
        try check(TabSiteIconStore.pageScope("https://EXAMPLE.test/path?a=b") == "https://example.test:443"
            && TabSiteIconStore.pageScope("https://example.test:443/other") == "https://example.test:443",
            "Same-origin navigation retains a tab's last valid icon without caching its path as identity")

        var completed = false
        var results: [(Bool, String)] = []
        let task = Task { @MainActor in
            var fetches = 0
            let store = TabSiteIconStore(capacity: 3) { address in
                fetches += 1
                await Task.yield()
                return address.path == "/broken" ? nil : bytes
            }
            let page = "https://example.test/work"
            let iconURL = "https://example.test/icon.png"
            var imageA: NSImage?, imageB: NSImage?
            let first = Task { @MainActor in
                imageA = await store.load(url: iconURL, pageURL: page, identity: "firefox:session:1")
            }
            let second = Task { @MainActor in
                imageB = await store.load(url: iconURL, pageURL: page, identity: "firefox:session:2")
            }
            await first.value; await second.value
            results.append((imageA != nil && imageA === imageB && fetches == 1,
                "Concurrent tab rows share one in-flight favicon request and decoded image"))
            results.append((store.cached(url: nil, pageURL: "https://example.test/next", identity: "firefox:session:1") === imageA,
                "A temporarily missing favicon survives snapshot refresh and same-site navigation"))
            results.append((store.cached(url: nil, pageURL: "https://other.test", identity: "firefox:session:1") == nil
                && store.cached(url: nil, pageURL: page, identity: "firefox:new-session:1") == nil,
                "Tab navigation to another site and reused IDs after browser restart cannot inherit the old site's icon"))
            let retained = await store.load(url: "https://example.test/broken", pageURL: page, identity: "firefox:session:1")
            _ = await store.load(url: "https://example.test/broken", pageURL: page, identity: "firefox:session:1")
            results.append((retained === imageA && fetches == 2,
                "A transient fetch failure retains the good icon and suppresses repeated failing requests"))
            _ = await store.load(url: "chrome://favicon/secret", pageURL: page, identity: "firefox:session:1")
            _ = await store.load(url: nil, pageURL: page, identity: "no-icon")
            results.append((fetches == 2,
                "Missing or browser-private favicons never cause invented requests to websites or third-party services"))
            let small = TabSiteIconStore(capacity: 1) { _ in bytes }
            _ = await small.load(url: iconURL, pageURL: page, identity: "a")
            _ = await small.load(url: "https://example.test/two.png", pageURL: page, identity: "b")
            results.append((small.cached(url: nil, pageURL: page, identity: "a") == nil
                && small.cached(url: nil, pageURL: page, identity: "b") != nil,
                "The in-memory tab icon cache evicts old entries at its fixed limit"))
            var olderReply: CheckedContinuation<Data?, Never>?
            var olderStarted: CheckedContinuation<Void, Never>?
            let racing = TabSiteIconStore { address in
                if address.path == "/older" {
                    return await withCheckedContinuation {
                        olderReply = $0
                        olderStarted?.resume(); olderStarted = nil
                    }
                }
                return bytes
            }
            var olderTask: Task<Void, Never>?
            var olderImage: NSImage?
            await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
                olderStarted = ready
                olderTask = Task { @MainActor in
                    olderImage = await racing.load(url: "https://example.test/older", pageURL: page, identity: "same-tab")
                }
            }
            let latestImage = await racing.load(url: "https://example.test/latest", pageURL: page, identity: "same-tab")
            olderReply?.resume(returning: bytes)
            await olderTask?.value
            results.append((olderImage != nil && latestImage != nil
                && racing.cached(url: nil, pageURL: page, identity: "same-tab") === latestImage,
                "An older icon response cannot overwrite a newer favicon when snapshot tasks finish out of order"))
            var canceledResult: NSImage?
            let canceledRow = Task { @MainActor in
                canceledResult = await racing.load(url: "https://example.test/cancelled-row", pageURL: page, identity: "cancelled-row")
            }
            canceledRow.cancel()
            await canceledRow.value
            results.append((canceledResult != nil
                && racing.cached(url: nil, pageURL: page, identity: "cancelled-row") === canceledResult,
                "A disappearing lazy row does not cancel or discard its reusable favicon fetch"))
            completed = true
        }
        let deadline = Date().addingTimeInterval(2)
        while !completed, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        task.cancel()
        try check(completed, "Injected favicon cache requests complete without real browser or network access")
        for (passed, label) in results { try check(passed, label) }
    }
}
