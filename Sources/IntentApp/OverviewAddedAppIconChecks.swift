import AppKit
import IntentCore
import SwiftUI

/// Render the production icon offscreen; no desktop window, input or launch.
@MainActor
enum OverviewAddedAppIconChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        guard IntentEnvironment.isQA else { throw failure("Staged icon checks require an isolated QA workspace") }
        let icon = NSImage(size: CGSize(width: 128, height: 128))
        icon.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: CGRect(x: 32, y: 32, width: 64, height: 64), xRadius: 12, yRadius: 12).fill()
        icon.unlockFocus()
        for (mode, selected, opening, hovered) in [
            (IntentionAccessMode.whitelist, true, false, false),
            (.whitelist, true, true, true), (.blacklist, true, false, false), (.whitelist, false, false, false)
        ] {
            let view = OverviewAddedAppIcon(icon: icon, name: "QA staged app", selected: selected,
                selectionColor: mode == .blacklist ? .red : .green, opening: opening, hovered: hovered,
                size: 128, select: {}, remove: {})
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(x: 0, y: 0, width: 128, height: 128)
            host.layoutSubtreeIfNeeded()
            try check(host.window == nil, "Staged app icon rendering never orders a window or steals focus")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("No staged app bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var green = 0, red = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.35 else { continue }
                let r = pixel.redComponent, g = pixel.greenComponent, b = pixel.blueComponent
                if g > 0.45 && g > r * 1.4 && g > b * 1.4 { green += 1 }
                if r > 0.45 && r > g * 1.4 && r > b * 1.4 { red += 1 }
            } }
            let expected = mode == .blacklist ? red : green
            let other = mode == .blacklist ? green : red
            try check(selected ? expected > 75 && other == 0 : green == 0 && red == 0,
                "The actual icon renderer shows the correct allow/block outline immediately, retains it during loading and hover, and removes it when unselected")
            try check(green + red < bitmap.pixelsWide * bitmap.pixelsHigh / 4,
                "Selection is a thin icon outline, never a filled background card")
        }
        try checkRemovalControls(icon: icon, check: check)
    }

    private static func checkRemovalControls(icon: NSImage, check: (Bool, String) throws -> Void) throws {
        for mode in IntentionAccessMode.allCases {
            for ownedAddition in [false, true] {
                var captures: [Bool: Data] = [:]
                for hovered in [false, true] {
                    let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    let removal: (() -> Void)? = ownedAddition ? {} : nil
                    let view = OverviewAddedAppIcon(icon: icon, name: "QA staged app", selected: true,
                        selectionColor: mode == .blacklist ? .red : .green, opening: false, hovered: hovered,
                        size: 128, select: {}, remove: removal)
                        .preferredColorScheme(.dark).environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: .darkAqua)
                    host.frame = CGRect(x: 0, y: 0, width: 128, height: 128)
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("No removal-control bitmap") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let image = bitmap.representation(using: .png, properties: [:]) else { throw failure("No removal-control PNG") }
                    captures[hovered] = image
                    let caseDetail = "mode=\(mode.rawValue), owned=\(ownedAddition), hovered=\(hovered)"
                    try check(host.window == nil, "Removal-control regressions never order or attach a desktop window: \(caseDetail)")
                    try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                        "Rendering the production removal control never activates or changes the foreground app: \(caseDetail)")
                }
                try check(ownedAddition ? captures[false] != captures[true] : captures[false] == captures[true],
                    "Hover paints an X only for owned additions; an existing app’s green/red icon remains unchanged: mode=\(mode.rawValue), owned=\(ownedAddition)")
            }
        }
    }

    // macOS returns an empty accessibility tree for unattached and never-ordered
    // SwiftUI hosts, including positive controls. Do not mistake that for proof
    // of absent actions. Native accessibility acceptance requires a visible host;
    // these input-free checks instead verify the production rendering itself.
    private static func failure(_ detail: String) -> NSError {
        NSError(domain: "OverviewAddedAppIconChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
