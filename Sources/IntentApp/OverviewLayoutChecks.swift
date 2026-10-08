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
