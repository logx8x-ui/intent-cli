import AppKit
import SwiftUI
import IntentCore

enum GraphTheme {
    static func background(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.025, green: 0.028, blue: 0.034)
            : Color(red: 0.965, green: 0.970, blue: 0.978)
    }

    static func chrome(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.050, green: 0.054, blue: 0.064)
            : Color.white
    }

    static func surface(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.080, green: 0.085, blue: 0.100)
            : Color.white
    }

    static func elevatedSurface(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.112, blue: 0.132)
            : Color(red: 0.985, green: 0.988, blue: 0.994)
    }

    static func text(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.955, green: 0.960, blue: 0.970) : Color(red: 0.08, green: 0.085, blue: 0.10)
    }

    static func muted(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.58, green: 0.60, blue: 0.65) : Color(red: 0.39, green: 0.41, blue: 0.46)
    }

    static func stroke(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.22) : .black.opacity(0.18)
    }

    static let editBlue = Color(red: 0.46, green: 0.66, blue: 1.0)
}

struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension View {
    func graphMenuPanel(colorScheme: ColorScheme) -> some View {
        self
            .padding(15)
            .background(GraphTheme.elevatedSurface(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(GraphTheme.stroke(colorScheme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.48 : 0.14), radius: 22, y: 12)
    }
}

extension GraphPoint {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}
