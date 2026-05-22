import AppKit
import SwiftUI

enum AnkiTheme {
    static let accent = Color(red: 0.81, green: 0.74, blue: 1.00)
    static let commandPurple = Color(red: 0.65, green: 0.55, blue: 1.00)
    static let darkDetailBackground = Color(red: 0.075, green: 0.075, blue: 0.095)
    static let darkSidebarBackground = Color(red: 0.055, green: 0.055, blue: 0.075)
    static let lightDetailBackground = Color(red: 0.965, green: 0.970, blue: 0.985)
    static let lightSidebarBackground = Color(red: 0.910, green: 0.920, blue: 0.945)

    static func windowBackground(for appearance: String) -> NSColor {
        if appearance == "light" {
            return NSColor(calibratedRed: 0.965, green: 0.970, blue: 0.985, alpha: 1)
        }
        return NSColor(calibratedRed: 0.075, green: 0.075, blue: 0.095, alpha: 1)
    }

    static let detailBackground = themedColor(
        light: NSColor(calibratedRed: 0.965, green: 0.970, blue: 0.985, alpha: 1),
        dark: NSColor(calibratedRed: 0.075, green: 0.075, blue: 0.095, alpha: 1)
    )

    static let sidebarBackground = themedColor(
        light: NSColor(calibratedRed: 0.910, green: 0.920, blue: 0.945, alpha: 1),
        dark: NSColor(calibratedRed: 0.055, green: 0.055, blue: 0.075, alpha: 1)
    )

    static let panelBackground = themedColor(
        light: NSColor(calibratedRed: 0.995, green: 0.995, blue: 1.000, alpha: 0.94),
        dark: NSColor(calibratedRed: 0.120, green: 0.115, blue: 0.145, alpha: 0.82)
    )

    static let rowBackground = themedColor(
        light: NSColor(calibratedRed: 0.930, green: 0.940, blue: 0.970, alpha: 0.95),
        dark: NSColor(calibratedRed: 0.180, green: 0.170, blue: 0.215, alpha: 0.78)
    )

    static let stroke = themedColor(
        light: NSColor(calibratedRed: 0.790, green: 0.805, blue: 0.865, alpha: 0.8),
        dark: NSColor(calibratedRed: 0.360, green: 0.330, blue: 0.430, alpha: 0.7)
    )

    static let softStroke = themedColor(
        light: NSColor(calibratedRed: 0.790, green: 0.805, blue: 0.865, alpha: 0.35),
        dark: NSColor(calibratedRed: 0.900, green: 0.870, blue: 1.000, alpha: 0.10)
    )

    static let mutedText = themedColor(
        light: NSColor(calibratedRed: 0.390, green: 0.400, blue: 0.450, alpha: 1),
        dark: NSColor(calibratedRed: 0.790, green: 0.770, blue: 0.840, alpha: 1)
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
                RoundedRectangle(cornerRadius: 24)
                    .stroke(AnkiTheme.softStroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    func glassPanel(cornerRadius: CGFloat = 24, padding: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .background(AnkiTheme.panelBackground)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(AnkiTheme.softStroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
