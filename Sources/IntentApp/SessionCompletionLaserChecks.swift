import AppKit
import QuartzCore
import IntentCore

/// Inspects and samples the real finite CA layers. These checks never order a
/// window or claim to verify live animation/focus behaviour on the user's Mac.
@MainActor
enum SessionCompletionLaserChecks {
    static func run(check: (Bool, String) throws -> Void) throws {
        let size = CGSize(width: 1512, height: 982)
        for mode in IntentionAccessMode.allCases {
            let colour = SessionChromeStyle.accent(for: mode)
            for reduced in [false, true] {
                let root = makeRoot(size: size, colour: colour, reducedMotion: reduced)
                let layers = root.sublayers ?? []
                let strokes = layers.compactMap { $0 as? CAShapeLayer }
                try check(layers.count == (reduced ? 2 : 7), "Laser has bounded layers; reduced motion removes travelling tips and collision pulse")
                try check(strokes.allSatisfy { sameColour($0.strokeColor, colour.cgColor) && sameColour($0.shadowColor, colour.cgColor) },
                    "Every laser stroke and halo keeps the exact shared \(mode.rawValue) accent without whitening")
                try check(strokes.allSatisfy { $0.lineWidth <= 2.2 && $0.shadowRadius <= 2.2 && $0.fillColor == nil },
                    "Laser uses narrow strokes and restrained glow, not a broad luminous border")
                try check(layers.allSatisfy { $0.opacity == 0 && $0.shadowOffset == .zero },
                    "All model layers are invisible outside their finite animation and have centred glow")
                try check(layers.allSatisfy { layer in
                    let animations = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
                    return animations.count == 1 && animations.allSatisfy(isFinite)
                }, "All completion work is nonrepeating and bounded by the 1.05-second lifetime")

                if reduced {
                    try check(strokes.allSatisfy { $0.strokeStart == 0 && $0.strokeEnd == 1
                        && ($0.animation(forKey: "completion") as? CAKeyframeAnimation)?.keyPath == "opacity"
                        && $0.lineWidth == 1 && $0.shadowOpacity == 0 },
                        "Reduce Motion uses only a subtle static 1-point fade, with no travel or scale animation")
                } else {
                    let cores = strokes.filter { $0.name?.hasSuffix(".core") == true }
                    try check(cores.count == 2 && cores.allSatisfy { $0.lineWidth == 1 }, "Both laser cores are exactly 1 point wide")
                    try check(strokes.allSatisfy { stroke in
                        guard let group = stroke.animation(forKey: "completion") as? CAAnimationGroup,
                              let head = frames(group, key: "strokeEnd"), let tail = frames(group, key: "strokeStart"),
                              let headValues = head.values as? [NSNumber], let tailValues = tail.values as? [NSNumber],
                              headValues.count == tailValues.count else { return false }
                        return zip(headValues, tailValues).allSatisfy { head, tail in
                            (0...1).contains(tail.doubleValue) && tail.doubleValue <= head.doubleValue && head.doubleValue <= 1
                        } && headValues.last?.doubleValue == 1 && tailValues.last?.doubleValue == 1
                    }, "Travelling tails never overtake their heads or wrap; all collapse after the tips meet")
                    try check(cores.allSatisfy { stroke in
                        guard let path = stroke.path,
                              let group = stroke.animation(forKey: "completion") as? CAAnimationGroup,
                              let head = frames(group, key: "strokeEnd"), let tail = frames(group, key: "strokeStart"),
                              let headValue = value(head, elapsed: 0.38), let tailValue = value(tail, elapsed: 0.38) else { return false }
                        let length = CGFloat(headValue - tailValue) * SessionCompletionLight.pathLength(path)
                        return abs(length - 76) < 0.1
                    }, "Core tails remain 76 screen points rather than spanning a large fraction of the screen")
                    let meeting = layers.first { $0.name == "laser.meeting" }
                    try check(meeting.map { sameColour($0.backgroundColor, colour.cgColor)
                        && sameColour($0.shadowColor, colour.cgColor) && $0.bounds.width == 2.5 && $0.shadowRadius == 2.5 } == true,
                        "The small meeting pulse uses the same mode colour, never a white flash")
                    if let group = meeting?.animation(forKey: "meeting") as? CAAnimationGroup,
                       let opacity = frames(group, key: "opacity") {
                        try check(value(opacity, elapsed: SessionCompletionLight.travelDuration) == 0,
                            "The meeting pulse cannot light before both tips arrive")
                    } else {
                        try check(false, "The meeting pulse has a finite opacity animation")
                    }
                }

                let samples = reduced ? [0.25] : [0.19, 0.38, 0.57, 0.79, 0.94]
                for (index, elapsed) in samples.enumerated() {
                    let sampled = makeRoot(size: size, colour: colour, reducedMotion: reduced)
                    try sample(sampled, elapsed: elapsed)
                    let png = try render(sampled, size: size)
                    let label = reduced ? "reduced" : "frame-\(index + 1)"
                    try png.write(to: IntentEnvironment.dataDirectory.appendingPathComponent("completion-\(mode.rawValue)-\(label).png"))
                    try check(!png.isEmpty, "Actual \(mode.rawValue) laser layers render at \(elapsed)s without a live window")
                }
            }
        }
    }

    private static func makeRoot(size: CGSize, colour: NSColor, reducedMotion: Bool) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        SessionCompletionLight.installLayers(on: root, size: size, notchLeft: 656, notchRight: 856,
            colour: colour, reducedMotion: reducedMotion)
        return root
    }

    private static func sameColour(_ lhs: CGColor?, _ rhs: CGColor) -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let left = lhs?.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              let right = rhs.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              left.count == right.count else { return false }
        return zip(left, right).allSatisfy { abs($0 - $1) < 0.00001 }
    }

    private static func isFinite(_ animation: CAAnimation) -> Bool {
        guard animation.duration == SessionCompletionLight.duration,
              animation.duration <= 1.2, animation.repeatCount == 0, animation.repeatDuration == 0,
              animation.speed == 1, animation.timeOffset == 0, animation.beginTime == 0,
              animation.isRemovedOnCompletion, !animation.autoreverses else { return false }
        if let group = animation as? CAAnimationGroup {
            return group.animations?.isEmpty == false && group.animations?.allSatisfy(isFinite) == true
        }
        guard let frames = animation as? CAKeyframeAnimation,
              let values = frames.values as? [NSNumber], let times = frames.keyTimes,
              values.count == times.count, times.first?.doubleValue == 0, times.last?.doubleValue == 1,
              frames.calculationMode == .linear else { return false }
        return values.allSatisfy { $0.doubleValue.isFinite }
            && zip(times, times.dropFirst()).allSatisfy { $0.doubleValue < $1.doubleValue }
    }

    private static func frames(_ group: CAAnimationGroup, key: String) -> CAKeyframeAnimation? {
        group.animations?.compactMap { $0 as? CAKeyframeAnimation }.first { $0.keyPath == key }
    }

    private static func value(_ frames: CAKeyframeAnimation, elapsed: TimeInterval) -> Double? {
        guard let values = frames.values as? [NSNumber], let times = frames.keyTimes,
              values.count == times.count, values.count >= 2, frames.calculationMode == .linear else { return nil }
        let progress = min(1, max(0, elapsed / frames.duration))
        for index in 1..<times.count where progress <= times[index].doubleValue {
            let start = times[index - 1].doubleValue, end = times[index].doubleValue
            let fraction = (progress - start) / (end - start)
            return values[index - 1].doubleValue + (values[index].doubleValue - values[index - 1].doubleValue) * fraction
        }
        return values.last?.doubleValue
    }

    /// Sample the installed CAKeyframeAnimation objects, not a parallel drawing
    /// implementation. Production remains entirely compositor-driven.
    private static func sample(_ root: CALayer, elapsed: TimeInterval) throws {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for layer in root.sublayers ?? [] {
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key) else { continue }
                let animations = (animation as? CAAnimationGroup)?.animations ?? [animation]
                for animation in animations {
                    guard let frames = animation as? CAKeyframeAnimation,
                          let keyPath = frames.keyPath, let sampled = value(frames, elapsed: elapsed) else {
                        throw NSError(domain: "SessionCompletionLaserChecks", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Unsupported animation in actual laser preview"])
                    }
                    layer.setValue(sampled, forKeyPath: keyPath)
                }
            }
            layer.removeAllAnimations()
        }
    }

    private static func render(_ root: CALayer, size: CGSize) throws -> Data {
        guard let colourSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                  bytesPerRow: 0, space: colourSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "SessionCompletionLaserChecks", code: 2)
        }
        context.setFillColor(NSColor(calibratedWhite: 0.045, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        root.render(in: context)
        // A PNG file by itself could be an empty dark canvas. Require actual
        // mode-coloured pixels from the sampled layer tree as well.
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw NSError(domain: "SessionCompletionLaserChecks", code: 4)
        }
        var colouredPixels = 0
        for row in 0..<context.height {
            for column in 0..<context.width {
                let index = row * context.bytesPerRow + column * 4
                let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
                if max(red, green, blue) - min(red, green, blue) > 8 { colouredPixels += 1 }
            }
        }
        guard colouredPixels > 2 else {
            throw NSError(domain: "SessionCompletionLaserChecks", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Sampled laser layers rendered no visible coloured pixels"])
        }
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SessionCompletionLaserChecks", code: 3)
        }
        return png
    }
}
