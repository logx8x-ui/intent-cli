import AppKit
import SwiftUI

enum AnkiTheme {
    static let accent = Color(red: 0.50, green: 0.26, blue: 0.95)
    static let lightDetailBackground = Color(red: 0.96, green: 0.97, blue: 0.99)
    static let darkDetailBackground = Color(red: 0.07, green: 0.06, blue: 0.10)

    static let detailBackground = themedColor(
        light: NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1),
        dark: NSColor(calibratedRed: 0.07, green: 0.06, blue: 0.10, alpha: 1)
    )

    static let panelBackground = themedColor(
        light: NSColor(calibratedRed: 0.995, green: 0.995, blue: 1, alpha: 1),
        dark: NSColor(calibratedRed: 0.11, green: 0.09, blue: 0.14, alpha: 1)
    )

    static let rowBackground = themedColor(
        light: NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.98, alpha: 1),
        dark: NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.19, alpha: 1)
    )

    static let stroke = themedColor(
        light: NSColor(calibratedRed: 0.80, green: 0.82, blue: 0.88, alpha: 1),
        dark: NSColor(calibratedRed: 0.28, green: 0.25, blue: 0.34, alpha: 1)
    )

    private static func themedColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension View {
    func ankiPanel() -> some View {
        padding(16)
            .background(AnkiTheme.panelBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AnkiTheme.stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
