import AppKit
import SwiftUI
import IntentCore

enum GraphTheme {
    static func background(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.014, green: 0.016, blue: 0.020)
            : Color(red: 0.975, green: 0.978, blue: 0.984)
    }

    static func backdropTintOpacity(_ colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.46 : 0.58
    }

    static func chrome(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.035)
            : Color.white.opacity(0.58)
    }

    static func surface(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.045)
            : Color.white.opacity(0.50)
    }

    static func elevatedSurface(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.075)
            : Color.white.opacity(0.72)
    }

    static func text(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.955, green: 0.960, blue: 0.970) : Color(red: 0.08, green: 0.085, blue: 0.10)
    }

    static func muted(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.58, green: 0.60, blue: 0.65) : Color(red: 0.39, green: 0.41, blue: 0.46)
    }

    static func stroke(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.19) : .black.opacity(0.14)
    }

    static func glassTint(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.030) : .white.opacity(0.40)
    }

    static func glassHighlight(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.20) : .white.opacity(0.78)
    }

    static func glassShadow(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .black.opacity(0.42) : .black.opacity(0.10)
    }

    static func connection(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.30) : .black.opacity(0.25)
    }

    static let editBlue = Color(red: 0.46, green: 0.66, blue: 1.0)
}

struct AdaptiveBackdropView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
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

struct RoundedTriangleShape: Shape {
    var cornerRadius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let vertices = [
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        let radius = min(cornerRadius, min(rect.width, rect.height) * 0.18)

        func point(from start: CGPoint, toward end: CGPoint) -> CGPoint {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = max(sqrt(dx * dx + dy * dy), 0.001)
            let ratio = min(radius / length, 0.42)
            return CGPoint(x: start.x + dx * ratio, y: start.y + dy * ratio)
        }

        var path = Path()
        path.move(to: point(from: vertices[0], toward: vertices[1]))

        for index in 1...vertices.count {
            let vertexIndex = index % vertices.count
            let previousIndex = (vertexIndex + vertices.count - 1) % vertices.count
            let nextIndex = (vertexIndex + 1) % vertices.count
            let vertex = vertices[vertexIndex]

            path.addLine(to: point(from: vertex, toward: vertices[previousIndex]))
            path.addQuadCurve(
                to: point(from: vertex, toward: vertices[nextIndex]),
                control: vertex
            )
        }

        path.closeSubpath()
        return path
    }
}

extension View {
    func adaptiveGlassPanel(
        colorScheme: ColorScheme,
        cornerRadius: CGFloat,
        selected: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.ultraThinMaterial, in: shape)
            .background(GraphTheme.glassTint(colorScheme), in: shape)
            .overlay {
                shape
                    .fill(
                        LinearGradient(
                            colors: [GraphTheme.glassHighlight(colorScheme).opacity(0.34), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .stroke(
                        selected ? GraphTheme.editBlue.opacity(0.88) : GraphTheme.stroke(colorScheme),
                        lineWidth: selected ? 1.8 : 1
                    )
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .shadow(
                color: selected ? GraphTheme.editBlue.opacity(0.22) : GraphTheme.glassShadow(colorScheme),
                radius: selected ? 13 : 9,
                y: 5
            )
    }

    func graphMenuPanel(colorScheme: ColorScheme) -> some View {
        self
            .padding(15)
            .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 16)
    }
}

extension GraphPoint {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}
