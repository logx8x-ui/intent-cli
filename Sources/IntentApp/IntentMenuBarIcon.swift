import AppKit

@MainActor
enum IntentMenuBarIcon {
    static func makeImage() -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let stroke = NSColor.labelColor
            stroke.setStroke()

            func configure(_ path: NSBezierPath, width: CGFloat = 1.45) {
                path.lineWidth = width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }

            let square = NSBezierPath(
                roundedRect: NSRect(x: 1.1, y: 4.8, width: 7.1, height: 7.1),
                xRadius: 2.0,
                yRadius: 2.0
            )
            configure(square)

            let circle = NSBezierPath(ovalIn: NSRect(x: 16.2, y: 10.1, width: 4.6, height: 4.6))
            configure(circle)

            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: 18.45, y: 6.0))
            triangle.line(to: NSPoint(x: 21.1, y: 1.0))
            triangle.line(to: NSPoint(x: 15.8, y: 1.0))
            triangle.close()
            configure(triangle)

            let upperConnection = NSBezierPath()
            upperConnection.move(to: NSPoint(x: 8.1, y: 9.8))
            upperConnection.curve(
                to: NSPoint(x: 16.4, y: 12.25),
                controlPoint1: NSPoint(x: 11.0, y: 9.9),
                controlPoint2: NSPoint(x: 13.4, y: 12.5)
            )
            configure(upperConnection, width: 1.25)

            let lowerConnection = NSBezierPath()
            lowerConnection.move(to: NSPoint(x: 8.1, y: 7.1))
            lowerConnection.curve(
                to: NSPoint(x: 17.2, y: 5.15),
                controlPoint1: NSPoint(x: 11.6, y: 7.0),
                controlPoint2: NSPoint(x: 13.8, y: 4.2)
            )
            configure(lowerConnection, width: 1.25)

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Intent"
        return image
    }
}
