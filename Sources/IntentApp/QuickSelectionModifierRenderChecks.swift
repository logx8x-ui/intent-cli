import AppKit
import IntentCore
import SwiftUI

/// Captures the production editors, not a parallel mock or a golden image.
/// No window is created/ordered and no editor interaction is simulated here.
@MainActor
enum QuickSelectionModifierRenderChecks {
    static func run(check: (Bool, String) throws -> Void) throws {
        guard IntentEnvironment.isQA else { throw failure("Modifier rendering requires an isolated QA root") }
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for mode in IntentionAccessMode.allCases {
            var captures: [String: Data] = [:]
            for fixture in fixtures(mode: mode) {
                let content = QuickSelectionOptionsView(selection: .constant(fixture.selection), section: fixture.section, close: {})
                    .preferredColorScheme(.dark).environment(\.locale, Locale(identifier: "en_US_POSIX"))
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: .darkAqua)
                let fitting = host.fittingSize
                try check(abs(fitting.width - fixture.width) <= 1,
                          "Actual \(fixture.name) editor keeps its compact \(Int(fixture.width))-point width; got \(fitting)")
                try check(fitting.height >= fixture.minimumHeight && fitting.height <= fixture.maximumHeight,
                          "Actual \(fixture.name) editor lays out its controls within the compact height; got \(fitting)")
                host.frame = CGRect(origin: .zero, size: fitting)
                host.layoutSubtreeIfNeeded()
                try check(host.window == nil, "Modifier previews never attach to or order a desktop window")
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw failure("No AppKit bitmap for \(fixture.name)")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw failure("No PNG for \(fixture.name)")
                }
                let scale = CGFloat(bitmap.pixelsWide) / fitting.width
                try check(scale >= 1 && bitmap.pixelsHigh >= Int(fitting.height),
                          "Actual \(fixture.name) capture covers the full editor at native or Retina resolution")
                try check(brightPixelCount(bitmap) > 20,
                          "Actual \(fixture.name) editor renders visible control/text strokes, not just an empty dark image")
                if fixture.name == "checklist-empty" {
                    try check(ruledLineCount(bitmap, pointSize: fitting) == 3,
                              "The empty checklist actually renders exactly three separate full-width writing lines")
                }
                try png.write(to: IntentEnvironment.dataDirectory.appendingPathComponent("modifier-\(mode.rawValue)-\(fixture.name).png"))
                captures[fixture.name] = png
            }
            try check(captures["timer-two-minutes"] != captures["timer-twenty-four-hours"],
                      "Changing the timer from two minutes to twenty-four hours changes the rendered duration fields")
            try check(captures["checklist-empty"] != captures["checklist-written"],
                      "The actual checklist renderer displays entered text rather than retaining a blank placeholder image")
        }
        try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == before,
                  "Isolated modifier rendering did not activate Intent or change the foreground application")
    }

    private struct Fixture {
        var name: String
        var section: QuickSelectionOptionsSection
        var selection: QuickSelection
        var width: CGFloat
        var minimumHeight: CGFloat
        var maximumHeight: CGFloat
    }

    private static func fixtures(mode: IntentionAccessMode) -> [Fixture] {
        func timed(_ name: String, section: QuickSelectionOptionsSection, node: RestrictionNode) -> Fixture {
            var selection = QuickSelection(); selection.accessMode = mode; selection.restrictionNodes = [node]
            return .init(name: name, section: section, selection: selection, width: 206, minimumHeight: 65, maximumHeight: 110)
        }
        func checklist(_ name: String, tasks: [String]) -> Fixture {
            var selection = QuickSelection(); selection.accessMode = mode
            selection.frictionNodes = [.init(id: "qa-checklist-layout", friction: .taskChecklist(tasks), position: .zero)]
            return .init(name: name, section: .checklist, selection: selection, width: 276, minimumHeight: 125, maximumHeight: 160)
        }
        return [
            timed("timer-two-minutes", section: .timer, node: .init(id: "qa-duration-layout", kind: .timer, position: .zero, durationMinutes: 2)),
            timed("timer-twenty-four-hours", section: .timer, node: .init(id: "qa-duration-layout", kind: .timer, position: .zero, durationMinutes: 1440)),
            timed("timer-end-time", section: .timer, node: .init(id: "qa-end-layout", kind: .endTime, position: .zero, durationMinutes: 2,
                                                             endTimeHour: 23, endTimeMinute: 58, usesPresetEndTime: true)),
            timed("cooldown", section: .cooldown, node: .init(id: "qa-cooldown-layout", kind: .coolDown, position: .zero, durationMinutes: 92)),
            checklist("checklist-empty", tasks: ["", "", ""]),
            checklist("checklist-written", tasks: ["Draft the first paragraph", "한국어 문장 연습", "Review and send"])
        ]
    }

    private static func brightPixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.5 else { continue }
                if min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) > 0.55 { count += 1 }
            }
        }
        return count
    }

    /// Broad visual invariant, not a screenshot golden: three continuous writing
    /// rules inside the padding, irrespective of Retina scale or font rasterizer.
    private static func ruledLineCount(_ bitmap: NSBitmapImageRep, pointSize: CGSize) -> Int {
        let scaleX = CGFloat(bitmap.pixelsWide) / pointSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / pointSize.height
        let left = Int(14 * scaleX), right = bitmap.pixelsWide - Int(14 * scaleX)
        let first = Int(12 * scaleY), last = bitmap.pixelsHigh - Int(12 * scaleY)
        guard right > left, last > first else { return 0 }
        var groups = 0, wasLine = false
        for y in first..<last {
            var rulePixels = 0
            for x in left..<right {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.9 else { continue }
                let brightness = (pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3
                if brightness > 0.17 && brightness < 0.50 { rulePixels += 1 }
            }
            let isLine = CGFloat(rulePixels) >= CGFloat(right - left) * 0.85
            if isLine && !wasLine { groups += 1 }
            wasLine = isLine
        }
        return groups
    }

    private static func failure(_ detail: String) -> NSError {
        NSError(domain: "QuickSelectionModifierRenderChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
