import AppKit
import QuartzCore
import IntentCore

/// A finite Core Animation effect: no display link, input capture or application
/// activation. All completion causes use this same one-shot presentation.
@MainActor
final class SessionCompletionLight {
    private var panel: SessionCompletionPanel?
    private var dismissal: DispatchWorkItem?
    private var lastOccurrence: UUID?
    private var generation = UUID()
    static let duration: TimeInterval = 1.05
    static let travelDuration: TimeInterval = 0.76
    static let edgeInset: CGFloat = 3

    func show(occurrenceID: UUID, mode: IntentionAccessMode, screen: NSScreen) {
        guard lastOccurrence != occurrenceID else { return }
        lastOccurrence = occurrenceID
        hide()
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["CGSSessionScreenIsLocked"] as? Bool != true,
              session["kCGSSessionOnConsoleKey"] as? Bool != false,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { return }
        let light = Self.makePanel(frame: screen.frame)
        panel = light
        let content = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        light.contentView = content
        guard let root = content.layer else { hide(); return }
        root.contentsScale = screen.backingScaleFactor
        let layout = screen.intentNotchLayout()
        let notchLeft = layout.notchFrame.minX - screen.frame.minX
        let notchRight = layout.notchFrame.maxX - screen.frame.minX
        let colour = SessionChromeStyle.accent(for: mode)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Self.installLayers(on: root, size: screen.frame.size, notchLeft: notchLeft,
            notchRight: notchRight, colour: colour, reducedMotion: reduced)
        // orderFrontRegardless raises only this nonactivating, non-key panel.
        light.orderFrontRegardless()
        let currentGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.hide()
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    func hide() {
        generation = UUID()
        dismissal?.cancel(); dismissal = nil
        panel?.contentView?.layer?.removeAllAnimations()
        panel?.orderOut(nil); panel = nil
    }

    static func makePanel(frame: CGRect) -> SessionCompletionPanel {
        let panel = SessionCompletionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.isMovable = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }

    static func paths(size: CGSize, notchLeft: CGFloat, notchRight: CGFloat) -> [CGPath] {
        let inset = edgeInset, corner: CGFloat = 22
        let top = size.height - inset, bottom = inset, middle = size.width / 2
        return [true, false].map { left in
            let side = left ? inset : size.width - inset
            let inside = left ? side + corner : side - corner
            let path = CGMutablePath()
            path.move(to: CGPoint(x: left ? notchLeft : notchRight, y: top))
            path.addLine(to: CGPoint(x: inside, y: top))
            path.addQuadCurve(to: CGPoint(x: side, y: top - corner), control: CGPoint(x: side, y: top))
            path.addLine(to: CGPoint(x: side, y: bottom + corner))
            path.addQuadCurve(to: CGPoint(x: inside, y: bottom), control: CGPoint(x: side, y: bottom))
            path.addLine(to: CGPoint(x: middle, y: bottom))
            return path
        }
    }

    static func installLayers(on root: CALayer, size: CGSize, notchLeft: CGFloat, notchRight: CGFloat,
                              colour: NSColor, reducedMotion: Bool) {
        let paths = paths(size: size, notchLeft: notchLeft, notchRight: notchRight)
        for (index, path) in paths.enumerated() {
            let side = index == 0 ? "left" : "right"
            if reducedMotion {
                let line = makeLine(path: path, colour: colour, name: "laser.\(side).reduced", width: 1)
                line.contentsScale = root.contentsScale
                line.strokeStart = 0; line.strokeEnd = 1
                root.addSublayer(line)
                line.add(keyframes("opacity", values: [0, 0.28, 0], times: [0, 0.18, 1]), forKey: "completion")
                continue
            }

            // A longer, brighter cutting trace stays visible during the quick
            // sweep without widening the 1-point core. Length is in screen
            // points, not a broad fraction of the display perimeter. The small
            // leading tip and faint trailing halo retain the exact mode hue;
            // there is no white core or full-screen wash.
            let length = pathLength(path)
            let styles: [(name: String, width: CGFloat, tail: CGFloat, opacity: Double, glow: CGFloat)] = [
                ("glow", 2.2, 220, 0.30, 2.2),
                ("core", 1, 180, 0.96, 0.8),
                ("tip", 1.35, 12, 1, 1.3)
            ]
            for style in styles {
                let line = makeLine(path: path, colour: colour, name: "laser.\(side).\(style.name)", width: style.width)
                line.contentsScale = root.contentsScale
                line.strokeStart = 1; line.strokeEnd = 1
                line.shadowRadius = style.glow; line.shadowOpacity = style.name == "glow" ? 0.4 : 0.3
                root.addSublayer(line)
                let samples = strokeSamples(tailFraction: Double(style.tail / max(1, length)))
                let group = CAAnimationGroup()
                group.animations = [
                    keyframes("strokeEnd", values: samples.head, times: samples.times),
                    keyframes("strokeStart", values: samples.tail, times: samples.times),
                    keyframes("opacity", values: [0, style.opacity, style.opacity, 0, 0],
                        times: [0, 0.045 / duration, travelDuration / duration, 0.89 / duration, 1])
                ]
                group.duration = duration
                line.add(group, forKey: "completion")
            }
        }
        guard !reducedMotion else { return }
        // A restrained, same-colour collision pulse after the two tips meet.
        let spark = CALayer()
        spark.name = "laser.meeting"
        spark.contentsScale = root.contentsScale
        spark.bounds = CGRect(x: 0, y: 0, width: 2.5, height: 2.5)
        spark.position = CGPoint(x: size.width / 2, y: edgeInset); spark.cornerRadius = 1.25
        spark.backgroundColor = colour.cgColor; spark.opacity = 0
        spark.shadowColor = colour.cgColor; spark.shadowRadius = 2.5
        spark.shadowOpacity = 0.65; spark.shadowOffset = .zero
        root.addSublayer(spark)
        let meeting = CAAnimationGroup()
        meeting.animations = [
            keyframes("opacity", values: [0, 0, 0.95, 0.32, 0],
                times: [0, travelDuration / duration, 0.79 / duration, 0.87 / duration, 1]),
            keyframes("transform.scale", values: [0.7, 0.7, 1.8, 0.8],
                times: [0, travelDuration / duration, 0.84 / duration, 1])
        ]
        meeting.duration = duration
        spark.add(meeting, forKey: "meeting")
    }

    private static func makeLine(path: CGPath, colour: NSColor, name: String, width: CGFloat) -> CAShapeLayer {
        let line = CAShapeLayer()
        line.name = name; line.path = path; line.fillColor = nil
        line.strokeColor = colour.cgColor; line.lineWidth = width
        line.lineCap = .round; line.lineJoin = .round
        line.shadowColor = colour.cgColor; line.shadowOffset = .zero; line.shadowRadius = 0
        line.opacity = 0
        return line
    }

    private static func keyframes(_ key: String, values: [Double], times: [Double]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values.map { NSNumber(value: $0) }
        animation.keyTimes = times.map { NSNumber(value: $0) }
        animation.calculationMode = .linear
        animation.duration = duration
        return animation
    }

    private static func strokeSamples(tailFraction: Double) -> (head: [Double], tail: [Double], times: [Double]) {
        var heads: [Double] = [], tails: [Double] = [], times: [Double] = []
        // Explicit finite keyframes let isolated QA render the actual animation
        // values without opening a window or inventing a separate preview effect.
        for sample in 0...84 {
            let time = Double(sample) / 84 * duration
            let travel = min(1, time / travelDuration)
            let head = travel * travel * (3 - 2 * travel)
            let catchUp = min(1, max(0, (time - travelDuration) / 0.10))
            heads.append(head)
            tails.append(max(0, head - tailFraction * (1 - catchUp)))
            times.append(time / duration)
        }
        return (heads, tails, times)
    }

    /// Length approximation of our line/quadratic perimeter, only to keep the
    /// luminous tails a consistent physical size across display resolutions.
    static func pathLength(_ path: CGPath) -> CGFloat {
        var length: CGFloat = 0
        var previous = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                previous = element.points[0]
            case .addLineToPoint:
                let end = element.points[0]
                length += hypot(end.x - previous.x, end.y - previous.y)
                previous = end
            case .addQuadCurveToPoint:
                let start = previous, control = element.points[0], end = element.points[1]
                for step in 1...16 {
                    let t: CGFloat = CGFloat(step) / 16
                    let u: CGFloat = 1 - t
                    let startWeight: CGFloat = u * u
                    let controlWeight: CGFloat = 2 * u * t
                    let endWeight: CGFloat = t * t
                    let startX: CGFloat = startWeight * start.x
                    let controlX: CGFloat = controlWeight * control.x
                    let endX: CGFloat = endWeight * end.x
                    let startY: CGFloat = startWeight * start.y
                    let controlY: CGFloat = controlWeight * control.y
                    let endY: CGFloat = endWeight * end.y
                    let point = CGPoint(x: startX + controlX + endX, y: startY + controlY + endY)
                    length += hypot(point.x - previous.x, point.y - previous.y)
                    previous = point
                }
            default:
                break // The perimeter intentionally has no cubic/closed segments.
            }
        }
        return length
    }
}

final class SessionCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
