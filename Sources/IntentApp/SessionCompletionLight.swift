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
        let layout = screen.intentNotchLayout()
        let notchLeft = layout.frame.midX - screen.frame.minX - layout.notchWidth / 2
        let notchRight = layout.frame.midX - screen.frame.minX + layout.notchWidth / 2
        let colour = mode == .blacklist ? NSColor.systemRed : NSColor.systemGreen
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
        let inset: CGFloat = 3, corner: CGFloat = 22
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
        for path in paths {
            for glow in [true, false] {
                let line = CAShapeLayer()
                line.path = path; line.fillColor = nil
                line.strokeColor = (glow ? colour : colour.blended(withFraction: 0.65, of: .white)!).cgColor
                line.lineWidth = glow ? 5 : 1.6; line.lineCap = .round; line.lineJoin = .round
                line.shadowColor = colour.cgColor; line.shadowRadius = glow ? 9 : 2
                line.shadowOpacity = glow ? 0.9 : 0.6; line.shadowOffset = .zero
                line.opacity = 0
                root.addSublayer(line)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = reducedMotion ? [0, 0.45, 0] : [0, 1, 1, 0]
                fade.keyTimes = reducedMotion ? [0, 0.25, 1] : [0, 0.06, 0.72, 1]
                fade.duration = duration
                if reducedMotion { line.add(fade, forKey: "completion"); continue }
                let head = CABasicAnimation(keyPath: "strokeEnd")
                head.fromValue = 0; head.toValue = 1; head.duration = 0.72
                head.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                head.fillMode = .forwards
                let tail = CABasicAnimation(keyPath: "strokeStart")
                tail.fromValue = 0; tail.toValue = 1; tail.beginTime = 0.18; tail.duration = 0.75
                tail.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                tail.fillMode = .forwards
                let group = CAAnimationGroup(); group.animations = [head, tail, fade]; group.duration = duration
                line.add(group, forKey: "completion")
            }
        }
        guard !reducedMotion else { return }
        // Tiny meeting-point flash, not a full-screen brightness change.
        let spark = CALayer()
        spark.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
        spark.position = CGPoint(x: size.width / 2, y: 3); spark.cornerRadius = 2.5
        spark.backgroundColor = NSColor.white.cgColor; spark.opacity = 0
        spark.shadowColor = colour.cgColor; spark.shadowRadius = 12; spark.shadowOpacity = 1
        root.addSublayer(spark)
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 0, 1, 0]; pulse.keyTimes = [0, 0.66, 0.73, 1]; pulse.duration = duration
        spark.add(pulse, forKey: "meeting")
    }
}

final class SessionCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
