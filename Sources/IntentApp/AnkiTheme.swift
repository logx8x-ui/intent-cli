import AppKit
import SwiftUI

enum AnkiTheme {
    static let detailBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.13, alpha: 1)
            : NSColor(calibratedWhite: 0.95, alpha: 1)
    })

    static let panelBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : NSColor(calibratedWhite: 0.985, alpha: 1)
    })

    static let rowBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.22, alpha: 1)
            : NSColor(calibratedWhite: 0.91, alpha: 1)
    })

    static let stroke = Color.primary.opacity(0.08)
    static let accent = Color(nsColor: .systemGreen)
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
