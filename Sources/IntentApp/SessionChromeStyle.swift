import AppKit
import SwiftUI
import IntentCore

/// Shared by the notch dot and the laser; never whiten the mode's actual colour.
enum SessionChromeStyle {
    static let timingFontSize: CGFloat = 13
    static let titleFontSize: CGFloat = 10
    static let timingContentWidth: CGFloat = 67

    static func accent(for mode: IntentionAccessMode) -> NSColor {
        let semantic = NSColor(mode == .blacklist ? Color.red : Color.green)
        var resolved = semantic
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            if let rgb = semantic.usingColorSpace(.sRGB) {
                resolved = NSColor(srgbRed: rgb.redComponent, green: rgb.greenComponent,
                    blue: rgb.blueComponent, alpha: rgb.alphaComponent)
            }
        }
        return resolved
    }
}
