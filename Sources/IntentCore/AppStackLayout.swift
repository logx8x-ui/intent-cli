import Foundation
import CoreGraphics

/// Deterministic free-space packing of app groups. Every window uses the same
/// preview scale; a multi-window app receives a larger footprint, not a smaller
/// copy of a one-window tile. Only previews in the same app may overlap.
public enum AppStackLayout {
    public struct Item: Equatable, Sendable {
        public var id: UInt32
        public var app: String
        public var source: CGRect
        public var tabCount: Int
        public init(id: UInt32, app: String, source: CGRect, tabCount: Int = 0) {
            self.id = id; self.app = app; self.source = source; self.tabCount = tabCount
        }
    }
    public struct WindowPlacement: Equatable, Sendable {
        public var id: UInt32
        public var frame: CGRect
        public var captionFrame: CGRect
        public init(id: UInt32, frame: CGRect, captionFrame: CGRect) {
            self.id = id; self.frame = frame; self.captionFrame = captionFrame
        }
    }
    public struct Group: Equatable, Sendable {
        public var app: String
        /// Default front-to-back order. Hover changes layering, never geometry.
        public var ids: [UInt32]
        public var frame: CGRect
        public var windows: [WindowPlacement]
        public init(app: String, ids: [UInt32], frame: CGRect, windows: [WindowPlacement] = []) {
            self.app = app; self.ids = ids; self.frame = frame; self.windows = windows
        }
    }
    public static func groups(_ items: [Item], in bounds: CGRect, avoiding obstacle: CGRect? = nil) -> [Group] {
        guard !items.isEmpty, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return [] }
        let grouped = Dictionary(grouping: items, by: \.app)
        let names = grouped.keys.sorted()
        let windows = names.map { grouped[$0]!.sorted { $0.id < $1.id } }
        let centers = windows.map { group -> CGPoint in
            let valid = group.map(\.source).filter { $0.midX.isFinite && $0.midY.isFinite }
            guard !valid.isEmpty else { return .zero }
            return CGPoint(x: valid.map(\.midX).reduce(0, +) / CGFloat(valid.count),
                           y: valid.map(\.midY).reduce(0, +) / CGFloat(valid.count))
        }
        let minX = centers.map(\.x).min()!, maxX = centers.map(\.x).max()!
        let minY = centers.map(\.y).min()!, maxY = centers.map(\.y).max()!
        // Find the largest shared scale that fits the preview and caption
        // footprints. Sparse desktops can reach native size; crowded desktops
        // shrink only as far as their actual geometry requires.
        func layout(at scale: CGFloat, compose: Bool = false) -> [Group]? {
            let spreads = windows.map { spread($0, scale: scale) }
            let sizes = spreads.map { spread in
                spread.reduce(CGRect.null) { $0.union($1.frame).union($1.captionFrame) }.size
            }
            let target = usableCenter(in: bounds, avoiding: obstacle)
            let wanted = centers.map { source in
                // Source positions retain a little spatial familiarity; they
                // must not stretch a compact app cluster to every screen edge.
                CGPoint(x: target.x + (maxX > minX ? (source.x - minX) / (maxX - minX) - 0.5 : 0) * bounds.width * 0.24,
                        y: target.y + (maxY > minY ? (source.y - minY) / (maxY - minY) - 0.5 : 0) * bounds.height * 0.24)
            }
            let weights = spreads.map { $0.reduce(CGFloat.zero) { $0 + $1.frame.width * $1.frame.height } }
            let localCenters = spreads.indices.map { index -> CGPoint in
                let group = spreads[index]
                let total = group.reduce(CGFloat.zero) { $0 + $1.frame.width * $1.frame.height }
                guard total > 0 else { return CGPoint(x: sizes[index].width / 2, y: sizes[index].height / 2) }
                let x = group.reduce(CGFloat.zero) { $0 + $1.frame.midX * $1.frame.width * $1.frame.height }
                let y = group.reduce(CGFloat.zero) { $0 + $1.frame.midY * $1.frame.width * $1.frame.height }
                return CGPoint(x: x / total, y: y / total)
            }
            guard let placed = pack(sizes, wanted: wanted, weights: weights, localCenters: localCenters,
                                    in: bounds, avoiding: obstacle, compose: compose) else { return nil }
            return names.indices.map { index in
                let frame = placed[index]
                let ordered = windows[index].sorted {
                    if $0.tabCount != $1.tabCount { return $0.tabCount > $1.tabCount }
                    return $0.id < $1.id
                }
                let positions = spreads[index].map {
                    WindowPlacement(id: $0.id,
                                    frame: $0.frame.offsetBy(dx: frame.minX, dy: frame.minY),
                                    captionFrame: $0.captionFrame.offsetBy(dx: frame.minX, dy: frame.minY))
                }
                return Group(app: names[index], ids: ordered.map(\.id), frame: frame, windows: positions)
            }
        }
        if let native = layout(at: 1, compose: true) { return native }
        if layout(at: 0) != nil {
            var lower: CGFloat = 0, upper: CGFloat = 1
            var best: [Group]?
            // Fixed iterations bound refresh cost and avoid the old ten-percent
            // jumps, which left usable space empty even after a safe pack fit.
            for _ in 0..<16 {
                let scale = (lower + upper) / 2
                if let candidate = layout(at: scale) { lower = scale; best = candidate }
                else { upper = scale }
            }
            if let best { return layout(at: lower, compose: true) ?? best }
        }
        // Unusually crowded displays still show every window directly. Do not
        // replace the overview with an app-specific sheet or silently omit IDs.
        let ordered = items.sorted { $0.id < $1.id }
        let frames = obstacle.map { FieldOfViewLayout.frames(sourceFrames: ordered.map(\.source), in: bounds, avoiding: $0) }
            ?? FieldOfViewLayout.frames(sourceFrames: ordered.map(\.source), in: bounds, tabHeight: 0)
        guard frames.count == ordered.count else { return [] }
        return names.map { name in
            let positions = ordered.indices.filter { ordered[$0].app == name }.map { index in
                let frame = frames[index]
                return WindowPlacement(id: ordered[index].id, frame: frame,
                                       captionFrame: CGRect(x: frame.midX - max(110, frame.width) / 2,
                                                            y: frame.maxY, width: max(110, frame.width), height: FieldOfViewLayout.captionHeight))
            }
            return Group(app: name, ids: positions.map(\.id),
                         frame: positions.reduce(CGRect.null) { $0.union($1.frame).union($1.captionFrame) }, windows: positions)
        }
    }

    /// Split the remaining empty rectangles at occupied edges, instead of
    /// sampling a coarse screen grid. Feasibility determines preview size;
    /// composition then gathers those unchanged footprints around the center.
    private static func pack(_ sizes: [CGSize], wanted: [CGPoint], weights: [CGFloat], localCenters: [CGPoint],
                             in bounds: CGRect, avoiding obstacle: CGRect?, compose: Bool) -> [CGRect]? {
        let margin: CGFloat = 9
        let area = bounds.insetBy(dx: -margin, dy: -margin)
        var initial = [area]
        if let obstacle, obstacle.minX.isFinite, obstacle.minY.isFinite,
           obstacle.width.isFinite, obstacle.height.isFinite, !obstacle.isEmpty {
            initial = subtract(obstacle, from: initial)
        }
        var orders: [[Int]] = []
        for dimension in 0...2 {
            let order = sizes.indices.sorted {
                let a = dimension == 0 ? sizes[$0].width * sizes[$0].height : (dimension == 1 ? sizes[$0].width : sizes[$0].height)
                let b = dimension == 0 ? sizes[$1].width * sizes[$1].height : (dimension == 1 ? sizes[$1].width : sizes[$1].height)
                return a == b ? $0 < $1 : a > b
            }
            if !orders.contains(order) { orders.append(order) }
        }
        var best: [CGRect]?, bestScore = CGFloat.infinity
        for order in orders { for prioritizeFit in [true, false] {
            var free = initial
            var placed = Array(repeating: CGRect.zero, count: sizes.count)
            var finished = true
            for index in order {
                let size = CGSize(width: sizes[index].width + margin * 2, height: sizes[index].height + margin * 2)
                var chosen: CGRect?, bestShort = CGFloat.infinity, bestLong = CGFloat.infinity, bestDistance = CGFloat.infinity
                for region in free where size.width <= region.width && size.height <= region.height {
                    let short = min(region.width - size.width, region.height - size.height)
                    let long = max(region.width - size.width, region.height - size.height)
                    let xs = [region.minX, region.maxX - size.width]
                    let ys = [region.minY, region.maxY - size.height]
                    for x in xs { for y in ys {
                        // Center a sole app in its usable rectangle. Multiple
                        // groups anchor at free edges so they cannot strand a
                        // large empty border around an arbitrarily centered tile.
                        let candidate = sizes.count == 1
                            ? CGRect(x: min(max(region.minX, wanted[index].x - size.width / 2), region.maxX - size.width),
                                     y: min(max(region.minY, wanted[index].y - size.height / 2), region.maxY - size.height),
                                     width: size.width, height: size.height)
                            : CGRect(x: x, y: y, width: size.width, height: size.height)
                        let dx = candidate.midX - wanted[index].x, dy = candidate.midY - wanted[index].y
                        let distance = dx * dx + dy * dy
                        let betterFit = short < bestShort || (short == bestShort && (long < bestLong || (long == bestLong && distance < bestDistance)))
                        let betterPosition = distance < bestDistance || (distance == bestDistance && (short < bestShort || (short == bestShort && long < bestLong)))
                        if prioritizeFit ? betterFit : betterPosition {
                            chosen = candidate; bestShort = short; bestLong = long; bestDistance = distance
                        }
                    } }
                }
                guard let chosen else { finished = false; break }
                placed[index] = chosen.insetBy(dx: margin, dy: margin)
                free = subtract(chosen, from: free)
            }
            if finished {
                let candidates = compose
                    ? [placed, compact(placed, wanted: wanted, localCenters: localCenters, weights: weights,
                                       in: bounds, avoiding: obstacle, horizontalFirst: true),
                       compact(placed, wanted: wanted, localCenters: localCenters, weights: weights,
                               in: bounds, avoiding: obstacle, horizontalFirst: false)]
                    : [placed]
                for candidate in candidates {
                    let positioned = compose
                        ? centered(candidate, weights: weights, localCenters: localCenters, in: bounds, avoiding: obstacle)
                        : candidate
                    let score = compositionScore(positioned, weights: weights, localCenters: localCenters,
                                                 wanted: wanted, in: bounds, avoiding: obstacle)
                    if score < bestScore { best = positioned; bestScore = score }
                }
            }
        } }
        return best
    }

    private static func usableCenter(in bounds: CGRect, avoiding obstacle: CGRect?) -> CGPoint {
        guard let obstacle, obstacle.minX.isFinite, obstacle.minY.isFinite,
              obstacle.width.isFinite, obstacle.height.isFinite else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        let covered = bounds.intersection(obstacle.insetBy(dx: -9, dy: -9))
        let area = bounds.width * bounds.height
        guard !covered.isNull, covered.width * covered.height < area else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        let occupied = covered.width * covered.height, available = area - occupied
        return CGPoint(x: (area * bounds.midX - occupied * covered.midX) / available,
                       y: (area * bounds.midY - occupied * covered.midY) / available)
    }

    private static func previewCenter(_ frames: [CGRect], weights: [CGFloat], localCenters: [CGPoint]) -> CGPoint {
        let total = weights.reduce(0, +)
        guard total > 0 else {
            let cluster = frames.reduce(CGRect.null) { $0.union($1) }
            return CGPoint(x: cluster.midX, y: cluster.midY)
        }
        let x = frames.indices.reduce(CGFloat.zero) { $0 + (frames[$1].minX + localCenters[$1].x) * weights[$1] }
        let y = frames.indices.reduce(CGFloat.zero) { $0 + (frames[$1].minY + localCenters[$1].y) * weights[$1] }
        return CGPoint(x: x / total, y: y / total)
    }

    private static func compositionScore(_ frames: [CGRect], weights: [CGFloat], localCenters: [CGPoint], wanted: [CGPoint],
                                         in bounds: CGRect, avoiding obstacle: CGRect?) -> CGFloat {
        let target = usableCenter(in: bounds, avoiding: obstacle)
        let center = previewCenter(frames, weights: weights, localCenters: localCenters)
        let cluster = frames.reduce(CGRect.null) { $0.union($1) }
        let massX = (center.x - target.x) / bounds.width, massY = (center.y - target.y) / bounds.height
        let edgeX = (cluster.midX - target.x) / bounds.width, edgeY = (cluster.midY - target.y) / bounds.height
        let familiarity = frames.indices.reduce(CGFloat.zero) { result, index in
            let x = (frames[index].midX - wanted[index].x) / bounds.width
            let y = (frames[index].midY - wanted[index].y) / bounds.height
            return result + (x * x + y * y) / CGFloat(frames.count)
        }
        return 12 * (massX * massX + massY * massY) + 2 * (edgeX * edgeX + edgeY * edgeY)
            + 0.05 * cluster.width * cluster.height / (bounds.width * bounds.height) + 0.01 * familiarity
    }

    /// Gather a feasible pack without changing scale or relative sibling
    /// geometry. The nearest intervening footprint bounds each axis movement.
    private static func compact(_ original: [CGRect], wanted: [CGPoint], localCenters: [CGPoint], weights: [CGFloat],
                                in bounds: CGRect, avoiding obstacle: CGRect?, horizontalFirst: Bool) -> [CGRect] {
        var frames = original
        let order = frames.indices.sorted { weights[$0] == weights[$1] ? $0 < $1 : weights[$0] > weights[$1] }
        let axes = horizontalFirst ? [true, false] : [false, true]
        for _ in 0..<3 { for horizontal in axes { for index in order {
            let frame = frames[index]
            var lower = horizontal ? bounds.minX : bounds.minY
            var upper = horizontal ? bounds.maxX - frame.width : bounds.maxY - frame.height
            var blockers = frames.indices.filter { $0 != index }.map { frames[$0].insetBy(dx: -18, dy: -18) }
            if let obstacle, obstacle.minX.isFinite, obstacle.minY.isFinite,
               obstacle.width.isFinite, obstacle.height.isFinite, !obstacle.isEmpty {
                blockers.append(obstacle.insetBy(dx: -9, dy: -9))
            }
            for blocker in blockers {
                let overlap = horizontal
                    ? frame.minY < blocker.maxY && frame.maxY > blocker.minY
                    : frame.minX < blocker.maxX && frame.maxX > blocker.minX
                guard overlap else { continue }
                let start = horizontal ? frame.minX : frame.minY, end = horizontal ? frame.maxX : frame.maxY
                let before = horizontal ? blocker.maxX : blocker.maxY, after = horizontal ? blocker.minX : blocker.minY
                if before <= start + 0.000001 { lower = max(lower, before) }
                else if after >= end - 0.000001 { upper = min(upper, after - (horizontal ? frame.width : frame.height)) }
                else { lower = start; upper = start; break }
            }
            guard lower <= upper else { continue }
            let wantedOrigin = horizontal ? wanted[index].x - localCenters[index].x : wanted[index].y - localCenters[index].y
            let origin = min(max(lower, wantedOrigin), upper)
            frames[index] = horizontal
                ? CGRect(x: origin, y: frame.minY, width: frame.width, height: frame.height)
                : CGRect(x: frame.minX, y: origin, width: frame.width, height: frame.height)
        } } }
        return frames
    }

    /// Center the whole cluster when there is room. Candidate offsets also
    /// include panel edges, so a top-corner log cannot strand all apps at the
    /// opposite edge. The fixed candidate limit keeps pointer refresh bounded.
    private static func centered(_ frames: [CGRect], weights: [CGFloat], localCenters: [CGPoint],
                                 in bounds: CGRect, avoiding obstacle: CGRect?) -> [CGRect] {
        let target = usableCenter(in: bounds, avoiding: obstacle)
        let mass = previewCenter(frames, weights: weights, localCenters: localCenters)
        let cluster = frames.reduce(CGRect.null) { $0.union($1) }
        let minX = bounds.minX - cluster.minX, maxX = bounds.maxX - cluster.maxX
        let minY = bounds.minY - cluster.minY, maxY = bounds.maxY - cluster.maxY
        func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat { min(max(lower, value), upper) }
        let wantedX = clamp((12 * (target.x - mass.x) + 2 * (target.x - cluster.midX)) / 14, minX, maxX)
        let wantedY = clamp((12 * (target.y - mass.y) + 2 * (target.y - cluster.midY)) / 14, minY, maxY)
        var xs = [wantedX, clamp(target.x - mass.x, minX, maxX), clamp(target.x - cluster.midX, minX, maxX), clamp(0, minX, maxX)]
        var ys = [wantedY, clamp(target.y - mass.y, minY, maxY), clamp(target.y - cluster.midY, minY, maxY), clamp(0, minY, maxY)]
        let validObstacle: CGRect? = obstacle.flatMap {
            $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite && !$0.isEmpty ? $0 : nil
        }
        if let obstacle = validObstacle {
            var extraX: [CGFloat] = [], extraY: [CGFloat] = []
            for frame in frames {
                extraX.append(clamp(obstacle.minX - 9 - frame.maxX, minX, maxX))
                extraX.append(clamp(obstacle.maxX + 9 - frame.minX, minX, maxX))
                extraY.append(clamp(obstacle.minY - 9 - frame.maxY, minY, maxY))
                extraY.append(clamp(obstacle.maxY + 9 - frame.minY, minY, maxY))
            }
            extraX.sort { abs($0 - wantedX) == abs($1 - wantedX) ? $0 < $1 : abs($0 - wantedX) < abs($1 - wantedX) }
            extraY.sort { abs($0 - wantedY) == abs($1 - wantedY) ? $0 < $1 : abs($0 - wantedY) < abs($1 - wantedY) }
            xs.append(contentsOf: extraX.prefix(8)); ys.append(contentsOf: extraY.prefix(8))
        }
        var best = frames, cost = CGFloat.infinity
        for x in xs { for y in ys {
            let candidate = frames.map { $0.offsetBy(dx: x, dy: y) }
            if let obstacle = validObstacle, candidate.contains(where: { $0.insetBy(dx: -9, dy: -9).intersects(obstacle) }) { continue }
            let center = previewCenter(candidate, weights: weights, localCenters: localCenters)
            let massX = (center.x - target.x) / bounds.width, massY = (center.y - target.y) / bounds.height
            let edgeX = (cluster.midX + x - target.x) / bounds.width, edgeY = (cluster.midY + y - target.y) / bounds.height
            let score = 12 * (massX * massX + massY * massY) + 2 * (edgeX * edgeX + edgeY * edgeY)
            if score < cost { best = candidate; cost = score }
        } }
        return best
    }

    /// Empty rectangles may overlap each other, but each is entirely clear of
    /// every occupied footprint. Keeping only maximal rectangles bounds the
    /// search without throwing away long horizontal or vertical free lanes.
    private static func subtract(_ occupied: CGRect, from free: [CGRect]) -> [CGRect] {
        var remaining: [CGRect] = []
        for region in free {
            guard region.intersects(occupied) else { remaining.append(region); continue }
            if occupied.minX > region.minX {
                remaining.append(CGRect(x: region.minX, y: region.minY, width: occupied.minX - region.minX, height: region.height))
            }
            if occupied.maxX < region.maxX {
                remaining.append(CGRect(x: occupied.maxX, y: region.minY, width: region.maxX - occupied.maxX, height: region.height))
            }
            if occupied.minY > region.minY {
                remaining.append(CGRect(x: region.minX, y: region.minY, width: region.width, height: occupied.minY - region.minY))
            }
            if occupied.maxY < region.maxY {
                remaining.append(CGRect(x: region.minX, y: occupied.maxY, width: region.width, height: region.maxY - occupied.maxY))
            }
        }
        let positive = remaining.filter { $0.width > 0 && $0.height > 0 }
        return positive.enumerated().filter { index, rectangle in
            !positive.enumerated().contains { other, container in
                other != index && container.contains(rectangle) && (container != rectangle || other < index)
            }
        }.map { $0.element }
    }

    private static func spread(_ items: [Item], scale: CGFloat) -> [WindowPlacement] {
        let sizes = items.map { item in
            CGSize(width: (item.source.width.isFinite ? max(1, item.source.width) : 1) * scale,
                   height: (item.source.height.isFinite ? max(1, item.source.height) : 1) * scale)
        }
        let width = max(110, sizes.map(\.width).max() ?? 0)
        let height = sizes.map(\.height).max() ?? 0
        let columns = items.count == 3 ? 3 : Int(ceil(sqrt(Double(items.count))))
        let captionWidth = min(width, max(110, min(240, width * 0.64)))
        // This central lane remains exposed even when a neighbour is in front.
        // Its title can never be painted onto another window's preview.
        let step = max(width * 0.80, (width + captionWidth) / 2 + 8)
        let stagger: [CGFloat] = [0, 0.54, 0.14, 0.42, 0.08]
        let rowHeight = height * 1.54 + FieldOfViewLayout.captionHeight + 18
        var result: [WindowPlacement] = []
        for index in items.indices {
            let row = index / columns, column = index % columns
            let rowCount = min(columns, items.count - row * columns)
            let rowInset = CGFloat(columns - rowCount) * step / 2
            let x = rowInset + CGFloat(column) * step
            let y = CGFloat(row) * rowHeight + (rowCount > 1 ? stagger[column % stagger.count] * height : 0)
            let size = sizes[index]
            let frame = CGRect(x: x + (width - size.width) / 2, y: y, width: size.width, height: size.height)
            let caption = CGRect(x: x + (width - captionWidth) / 2, y: frame.maxY + 6,
                                 width: captionWidth, height: FieldOfViewLayout.captionHeight)
            result.append(WindowPlacement(id: items[index].id, frame: frame, captionFrame: caption))
        }
        let origin = result.reduce(CGRect.null) { $0.union($1.frame).union($1.captionFrame) }.origin
        return result.map { WindowPlacement(id: $0.id, frame: $0.frame.offsetBy(dx: -origin.x, dy: -origin.y),
                                            captionFrame: $0.captionFrame.offsetBy(dx: -origin.x, dy: -origin.y)) }
    }
}
