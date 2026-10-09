import AppKit
import IntentCore
import SwiftUI

/// Measures the production footer and renders the same chrome layout used by
/// the overview. No panel is ordered and no browser or daily workspace is read.
@MainActor
enum OverviewLayoutChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        guard IntentEnvironment.isQA else { throw failure("Overview layout checks require isolated QA data") }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let model = IntentAppModel()
        let controller = QuickSelectionController(model: model)
        let source = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let items = (1...3).map { AppStackLayout.Item(id: UInt32($0), app: "browser", source: source) }
            + [AppStackLayout.Item(id: 4, app: "notes", source: source)]
        try checkRecentPanelGeometry(check)
        try checkProductionHeader(controller: controller, model: model, items: items, check)
        for hasMessage in [false, true] {
            controller.message = hasMessage ? "A saved browser needs attention before this intention can run." : nil
            for size in [CGSize(width: 800, height: 600), CGSize(width: 1280, height: 800), CGSize(width: 1710, height: 1112)] {
                let footer = OverviewFooter(controller: controller, model: model)
                    .frame(width: size.width).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white).preferredColorScheme(.dark)
                let footerHost = NSHostingView(rootView: footer)
                let footerHeight = footerHost.fittingSize.height
                try check(abs(footerHeight - (hasMessage ? 214 : 154)) <= 1,
                    "The actual overview footer reserves every row and gap, with/without feedback; got \(footerHeight)")
                for headerHeight in [CGFloat(48), 150, 218] {
                    let bounds = CGRect(origin: CGPoint(x: 17, y: 29), size: size)
                    let frames = OverviewChromeLayout.frames(in: bounds, headerHeight: headerHeight, footerHeight: footerHeight)
                    try check(frames.footer.maxY == bounds.maxY && bounds.contains(frames.canvas),
                        "The measured chrome and canvas remain within the viewport, including a nonzero origin")
                    try check(frames.canvas.maxY + OverviewChromeLayout.contentGap <= frames.footer.minY + 0.01
                        && frames.header.maxY + OverviewChromeLayout.contentGap <= frames.canvas.minY + 0.01,
                        "Header/footer reserve an explicit gap before any preview or caption")
                    let area = CGRect(x: 28, y: 0, width: frames.canvas.width - 56, height: frames.canvas.height)
                    let groups = AppStackLayout.groups(items, in: area)
                    let windows = groups.flatMap(\.windows)
                    try check(windows.count == items.count, "Chrome reservation does not silently omit app windows")
                    let firstSize = windows[0].frame.size
                    try check(windows.allSatisfy { $0.frame.size == firstSize },
                        "Multi-window and single-window apps retain the same preview scale")
                    for window in windows {
                        let card = window.frame.union(window.captionFrame)
                        let absolute = card.offsetBy(dx: frames.canvas.minX, dy: frames.canvas.minY)
                        try check(area.contains(card) && absolute.maxY + OverviewChromeLayout.contentGap <= frames.footer.minY + 0.01,
                            "The entire preview and caption remain above the actual modification/footer controls")
                    }
                }

                // Colored regions make the real Layout's placement measurable;
                // the footer remains the actual production controls, not a mock.
                let content = OverviewChromeLayout {
                    Color.red.frame(height: 150).fixedSize(horizontal: false, vertical: true)
                    Color(red: 0, green: 1, blue: 0)
                    footer.background(Color(red: 0, green: 0, blue: 1))
                }.frame(width: size.width, height: size.height).background(Color.black)
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                try check(host.window == nil && footerHost.window == nil, "Overview regression never orders a live window")
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw failure("No overview layout bitmap")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                // Keep evidence even when a later pixel assertion fails. The
                // viewport is part of the filename because the first failing
                // size may differ from the representative 1280-point capture.
                let imageURL = IntentEnvironment.dataDirectory.appendingPathComponent(
                    "overview-layout-\(hasMessage ? "message" : "normal")-\(Int(size.width))x\(Int(size.height)).png")
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw failure("No overview layout PNG")
                }
                try png.write(to: imageURL)
                let scale = CGFloat(bitmap.pixelsHigh) / size.height
                let rows = coloredRows(bitmap)
                let expected = OverviewChromeLayout.frames(in: CGRect(origin: .zero, size: size), headerHeight: 150, footerHeight: footerHeight)
                try check(abs(CGFloat(rows.canvas.count) / scale - expected.canvas.height) <= 2,
                    "Rendered canvas consumes only the space remaining after the actual header, footer and gaps")
                guard let canvasMin = rows.canvas.min(), let canvasMax = rows.canvas.max(),
                      let footerMin = rows.footer.min(), let footerMax = rows.footer.max() else {
                    throw failure("Actual overview chrome layout did not render its canvas and footer; canvas rows=\(rows.canvas.count), footer rows=\(rows.footer.count), capture=\(imageURL.path)")
                }
                try check(abs(CGFloat(rows.footer.count) / scale - footerHeight) <= 2,
                    "The rendered footer reserves its full measured height, including every row and gap")
                let gap = max(footerMin - canvasMax - 1, canvasMin - footerMax - 1)
                try check(CGFloat(gap) / scale >= OverviewChromeLayout.contentGap - 1,
                    "The rendered modifications footer never paints into the preview/caption canvas")
                if size.width == 1280 {
                    try png.write(to: IntentEnvironment.dataDirectory.appendingPathComponent("overview-layout-\(hasMessage ? "message" : "normal").png"))
                }
            }
        }
        try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
            "Isolated overview rendering preserves the foreground application")
    }

    private static func checkRecentPanelGeometry(_ check: (Bool, String) throws -> Void) throws {
        for viewport in [CGRect(x: 17, y: 29, width: 800, height: 600),
                         CGRect(x: -1200, y: 51, width: 1280, height: 800),
                         CGRect(x: 0, y: 0, width: 180, height: 300)] {
            let footer = CGRect(x: viewport.minX, y: viewport.maxY - 154, width: viewport.width, height: 154)
            let bounds = OverviewRecentPanelLayout.bounds(in: viewport, topSafeInset: 32, footer: footer)
            let size = OverviewRecentPanelLayout.size(in: bounds)
            try check(viewport.contains(bounds) && bounds.maxY <= footer.minY
                && size.width > 0 && size.height > 0 && size.width <= bounds.width && size.height <= bounds.height,
                "History remains inside its screen and above the actual footer on nonzero-origin and narrow displays")
            for position in [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0.27, y: 0.71), CGPoint(x: 1, y: 1)] {
                let origin = OverviewRecentPanelLayout.origin(position: position, size: size, in: bounds)
                guard let frame = OverviewRecentPanelLayout.frame(origin: origin, size: size, in: bounds, avoiding: []) else {
                    throw failure("An unobstructed recent-intentions position was omitted")
                }
                let restored = OverviewRecentPanelLayout.origin(
                    position: OverviewRecentPanelLayout.position(for: frame, in: bounds), size: frame.size, in: bounds)
                try check(bounds.contains(frame) && abs(restored.x - frame.minX) < 0.01 && abs(restored.y - frame.minY) < 0.01,
                    "Normalized history preferences round-trip without snapping on every supported viewport")
            }
            for origin in [CGPoint(x: bounds.minX - 1000, y: bounds.minY - 1000),
                           CGPoint(x: bounds.maxX + 1000, y: bounds.maxY + 1000)] {
                guard let frame = OverviewRecentPanelLayout.frame(origin: origin, size: size, in: bounds, avoiding: []) else {
                    throw failure("Dragging beyond the screen discarded the history panel")
                }
                try check(bounds.contains(frame), "Dragging beyond an edge clamps the complete history panel to visible bounds")
            }
            try check(OverviewRecentPanelLayout.frame(origin: bounds.origin, size: size, in: bounds, avoiding: [bounds]) == nil,
                "A fully occupied region cannot place history over protected controls")
        }
    }

    private static func checkProductionHeader(controller: QuickSelectionController, model: IntentAppModel,
                                             items: [AppStackLayout.Item], _ check: (Bool, String) throws -> Void) throws {
        let originalIntentions = model.intentions
        let originalJournal = model.journal
        let originalOnboarding = model.onboarding.state
        let originalPresented = model.onboarding.isPresented
        let originalCapacity = controller.savedSlotCapacity
        let originalPage = controller.savedSlotPage
        defer {
            model.intentions = originalIntentions; model.journal = originalJournal
            model.onboarding.state = originalOnboarding; model.onboarding.isPresented = originalPresented
            controller.savedSlotCapacity = originalCapacity; controller.savedSlotPage = originalPage
        }
        let fixture = (0..<9).map { index in
            Intention(id: "qa-overview-slot-\(index)", name: "Study setup \(index + 1)", icon: "book",
                colorHex: "#34C759", folder: "", allowedApps: [], allowedWebsites: [], startupActions: [], restrictions: .init())
        }
        for size in [CGSize(width: 800, height: 600), CGSize(width: 1280, height: 800), CGSize(width: 1710, height: 1112)] {
            controller.savedSlotCapacity = min(9, max(1, Int((size.width - 150) / 160)))
            controller.savedSlotPage = 0
            for topSafeInset in [CGFloat.zero, 32] {
                for teaching in [false, true] {
                    // Published state alone enables the real hint. Coordinator
                    // begin/present would enter runtime scope and start timers.
                    model.onboarding.state = .init(purpose: "QA layout")
                    model.onboarding.state.begin(now: Date(timeIntervalSinceReferenceDate: 1000))
                    model.onboarding.isPresented = teaching
                    var emptyHeight: CGFloat?
                    for slotCount in [0, 1, 9] {
                        model.intentions = Array(fixture.prefix(slotCount))
                        model.journal.slotOrder = model.intentions.map(\.id)
                        var headerRects: [String: CGRect] = [:]
                        let header = OverviewHeader(controller: controller, model: model, showClock: true, topSafeInset: topSafeInset, width: size.width)
                            .frame(width: size.width).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.white).preferredColorScheme(.dark)
                            .coordinateSpace(name: "IntentOverview")
                            .onPreferenceChange(IntentionFramePreference.self) { headerRects = $0 }
                        let headerHost = NSHostingView(rootView: header)
                        let height = headerHost.fittingSize.height
                        headerHost.sizingOptions = []
                        headerHost.frame = CGRect(x: 0, y: 0, width: size.width, height: height)
                        var expectedKeys: Set<String> = ["overview-name", "overview-clock"]
                        if slotCount > 0 { expectedKeys.insert("overview-saved") }
                        if teaching { expectedKeys.insert("overview-onboarding") }
                        var previousRects: [String: CGRect] = [:]
                        var settled = false
                        for _ in 0..<10 {
                            headerHost.layoutSubtreeIfNeeded()
                            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                            if expectedKeys.isSubset(of: Set(headerRects.keys)) && headerRects == previousRects {
                                settled = true; break
                            }
                            previousRects = headerRects
                        }
                        try check(settled, "Production header geometry settles before any history-placement assertion")
                        try check(headerHost.window == nil && height.isFinite && height >= topSafeInset,
                            "The actual production header measures safely without ordering a window")
                        if slotCount == 0 { emptyHeight = height }
                        else {
                            try check(height > (emptyHeight ?? height) + 60,
                                "Actual saved slots reserve their full row rather than painting into the preview canvas")
                        }
                        let controls = headerRects.filter { $0.key.hasPrefix("overview-") }.map(\.value)
                        try check(!controls.isEmpty && controls.allSatisfy { $0.width > 0 && $0.height > 0 && CGRect(x: 0, y: 0, width: size.width, height: height).contains($0) },
                            "Every protected production header control reports its actual bounded rectangle")
                        for footerHeight in [CGFloat(154), 214] {
                            let viewport = CGRect(x: 17, y: 29, width: size.width, height: size.height)
                            let frames = OverviewChromeLayout.frames(in: viewport, headerHeight: height, footerHeight: footerHeight)
                            let bounds = OverviewRecentPanelLayout.bounds(in: viewport, topSafeInset: topSafeInset, footer: frames.footer)
                            let panelSize = OverviewRecentPanelLayout.size(in: bounds)
                            let obstacles = controls.map { $0.offsetBy(dx: viewport.minX, dy: viewport.minY) }
                            for position in [CGPoint.zero, CGPoint(x: 1, y: 0)] {
                                let origin = OverviewRecentPanelLayout.origin(position: position, size: panelSize, in: bounds)
                                guard let panel = OverviewRecentPanelLayout.frame(origin: origin, size: panelSize, in: bounds, avoiding: obstacles) else {
                                    throw failure("Recent intentions could not find a safe position: \(Int(size.width))×\(Int(size.height)), top inset \(topSafeInset), saved items \(slotCount), guide \(teaching), footer \(footerHeight)")
                                }
                                try check(bounds.contains(panel) && obstacles.allSatisfy { !panel.intersects($0) },
                                    "Dragging history toward either upper corner avoids actual name, saved-slot, clock and onboarding controls")
                                if size.width == 800 && teaching && slotCount > 0 && footerHeight == 214 {
                                    try check(panel.width >= 180 && panel.height >= 60,
                                        "The compact saved-slots plus guide plus feedback fixture keeps a usable history header and scrollable log")
                                }
                                if !teaching && slotCount <= 1 && size.width >= 1280 {
                                    try check(panel.minY < frames.canvas.minY,
                                        "History can reach higher corner pockets instead of stopping at the old canvas boundary")
                                }
                                let area = CGRect(x: 28, y: 0, width: max(0, frames.canvas.width - 56), height: frames.canvas.height)
                                let translated = panel.offsetBy(dx: -frames.canvas.minX, dy: -frames.canvas.minY).intersection(area)
                                let groups = AppStackLayout.groups(items, in: area, avoiding: translated.isNull ? nil : translated)
                                let windows = groups.flatMap(\.windows)
                                try check(windows.count == items.count,
                                    "Translating high history positions into canvas coordinates never loses an app window")
                                for window in windows {
                                    let card = window.frame.union(window.captionFrame)
                                    let absolute = card.offsetBy(dx: frames.canvas.minX, dy: frames.canvas.minY)
                                    try check(area.contains(card) && !absolute.intersects(panel)
                                        && absolute.maxY + OverviewChromeLayout.contentGap <= frames.footer.minY + 0.01,
                                        "Larger previews and complete captions avoid moved history and measured footer controls")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func coloredRows(_ bitmap: NSBitmapImageRep) -> (canvas: [Int], footer: [Int]) {
        var canvas: [Int] = [], footer: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: 1, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            // AppKit's Generic RGB capture can gain secondary components when
            // converted to the display's RGB space (pure blue gains green).
            // Dominance distinguishes these markers from red, black, and gray
            // without assuming that color-managed zero remains exactly zero.
            let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
            if green > 0.8 && green - max(red, blue) > 0.5 { canvas.append(y) }
            if blue > 0.8 && blue - max(red, green) > 0.5 { footer.append(y) }
        }
        return (canvas, footer)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "OverviewLayoutChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
