import Foundation
import IntentCore

/// The log can use the upper corners, including unused space beside the
/// header. Only actual controls are obstacles, rather than the whole header.
enum OverviewRecentPanelLayout {
    static func bounds(in viewport: CGRect, topSafeInset: CGFloat, footer: CGRect) -> CGRect {
        let top = min(viewport.maxY, viewport.minY + max(0, topSafeInset) + 6)
        let bottom = max(top, min(viewport.maxY - 6, footer.minY - 12))
        return CGRect(x: viewport.minX + min(28, viewport.width / 2), y: top,
                      width: max(0, viewport.width - 56), height: bottom - top)
    }

    static func size(in bounds: CGRect) -> CGSize {
        CGSize(width: min(240, max(0, bounds.width)), height: min(260, max(0, bounds.height * 0.45)))
    }

    static func origin(position: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + max(0, bounds.width - size.width) * normalized(position.x),
                y: bounds.minY + max(0, bounds.height - size.height) * normalized(position.y))
    }

    static func position(for frame: CGRect, in bounds: CGRect) -> CGPoint {
        CGPoint(x: normalized((frame.minX - bounds.minX) / max(1, bounds.width - frame.width)),
                y: normalized((frame.minY - bounds.minY) / max(1, bounds.height - frame.height)))
    }

    static func frame(origin: CGPoint, size: CGSize, in bounds: CGRect, avoiding obstacles: [CGRect]) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0,
              [bounds.minX, bounds.minY, bounds.width, bounds.height, size.width, size.height].allSatisfy(\.isFinite) else { return nil }
        let safeOrigin = CGPoint(x: origin.x.isFinite ? origin.x : bounds.minX,
                                 y: origin.y.isFinite ? origin.y : bounds.minY)
        let desired = FieldOfViewLayout.panel(origin: safeOrigin, size: size, in: bounds)
        let protected = obstacles.filter { !$0.isEmpty && !$0.isNull
            && [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }
            .map { $0.insetBy(dx: -10, dy: -10) }
        func isClear(_ rect: CGRect) -> Bool {
            bounds.contains(rect) && protected.allSatisfy { !rect.intersects($0) }
        }
        if isClear(desired) { return desired }

        // The nearest clear position lies against a bounds or control edge.
        // A fixed candidate set keeps dragging fast and deterministic.
        let xs = [desired.minX, bounds.minX, bounds.maxX - desired.width]
            + protected.flatMap { [$0.minX - desired.width, $0.maxX] }
        let ys = [desired.minY, bounds.minY, bounds.maxY - desired.height]
            + protected.flatMap { [$0.minY - desired.height, $0.maxY] }
        var best: CGRect?
        var bestDistance = CGFloat.infinity
        for x in xs {
            for y in ys {
                let candidate = FieldOfViewLayout.panel(origin: CGPoint(x: x, y: y), size: desired.size, in: bounds)
                guard isClear(candidate) else { continue }
                let distance = pow(candidate.minX - desired.minX, 2) + pow(candidate.minY - desired.minY, 2)
                if distance < bestDistance {
                    best = candidate
                    bestDistance = distance
                }
            }
        }
        if let best { return best }

        // A small display can have saved slots, onboarding and feedback at
        // once. Keep the log visible in the remaining clear space, shortening
        // its scrolling body only when its normal size cannot fit anywhere.
        var free = [bounds]
        for obstacle in protected {
            free = free.flatMap { region -> [CGRect] in
                let cut = region.intersection(obstacle)
                guard !cut.isNull && !cut.isEmpty else { return [region] }
                return [
                    CGRect(x: region.minX, y: region.minY, width: max(0, cut.minX - region.minX), height: region.height),
                    CGRect(x: cut.maxX, y: region.minY, width: max(0, region.maxX - cut.maxX), height: region.height),
                    CGRect(x: region.minX, y: region.minY, width: region.width, height: max(0, cut.minY - region.minY)),
                    CGRect(x: region.minX, y: cut.maxY, width: region.width, height: max(0, region.maxY - cut.maxY))
                ].filter { $0.width > 0 && $0.height > 0 }
            }
        }
        let fullWidth = free.filter { $0.width >= desired.width }
        let candidates = fullWidth.isEmpty ? free : fullWidth
        var bestArea: CGFloat = 0
        for region in candidates {
            let candidate = FieldOfViewLayout.panel(origin: desired.origin,
                size: CGSize(width: min(desired.width, region.width), height: min(desired.height, region.height)), in: region)
            let area = candidate.width * candidate.height
            let distance = pow(candidate.minX - desired.minX, 2) + pow(candidate.minY - desired.minY, 2)
            if isClear(candidate) && (area > bestArea || (area == bestArea && distance < bestDistance)) {
                best = candidate; bestArea = area; bestDistance = distance
            }
        }
        return best
    }

    private static func normalized(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}
