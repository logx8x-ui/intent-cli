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
        func layout(at scale: CGFloat) -> [Group]? {
            let spreads = windows.map { spread($0, scale: scale) }
            let sizes = spreads.map { spread in
                spread.reduce(CGRect.null) { $0.union($1.frame).union($1.captionFrame) }.size
            }
            let wanted = centers.map { source in
                CGPoint(x: bounds.minX + (maxX > minX ? (source.x - minX) / (maxX - minX) : 0.5) * bounds.width,
                        y: bounds.minY + (maxY > minY ? (source.y - minY) / (maxY - minY) : 0.5) * bounds.height)
            }
            guard let placed = pack(sizes, wanted: wanted, in: bounds, avoiding: obstacle) else { return nil }
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
        if let native = layout(at: 1) { return native }
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
            if let best { return best }
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
    /// sampling a coarse screen grid. This keeps large previews close to their
    /// familiar source positions while still fitting tightly beside each other.
    private static func pack(_ sizes: [CGSize], wanted: [CGPoint], in bounds: CGRect, avoiding obstacle: CGRect?) -> [CGRect]? {
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
        var best: [CGRect]?, bestTravel = CGFloat.infinity
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
                let travel = placed.indices.reduce(CGFloat.zero) { result, index in
                    let dx = placed[index].midX - wanted[index].x, dy = placed[index].midY - wanted[index].y
                    return result + dx * dx + dy * dy
                }
                if travel < bestTravel { best = placed; bestTravel = travel }
            }
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
