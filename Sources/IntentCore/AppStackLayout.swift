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
        // Bounded spatial packing keeps the arrangement familiar without imposing
        // rows across the desktop. Sort the larger *group* footprints first.
        for attempt in 0..<36 {
            let scale = 0.42 * pow(0.90, Double(attempt))
            let spreads = windows.map { spread($0, scale: scale) }
            let sizes = spreads.map { spread in
                spread.reduce(CGRect.null) { $0.union($1.frame).union($1.captionFrame) }.size
            }
            var placed: [Int: CGRect] = [:]
            for index in names.indices.sorted(by: {
                let a = sizes[$0].width * sizes[$0].height, b = sizes[$1].width * sizes[$1].height
                return a == b ? $0 < $1 : a > b
            }) {
                let size = sizes[index]
                guard size.width <= bounds.width, size.height <= bounds.height else { break }
                let source = centers[index]
                let wanted = CGPoint(x: bounds.minX + (maxX > minX ? (source.x - minX) / (maxX - minX) : 0.5) * bounds.width,
                                     y: bounds.minY + (maxY > minY ? (source.y - minY) / (maxY - minY) : 0.5) * bounds.height)
                var best: CGRect?; var cost = CGFloat.infinity
                for y in 0...20 { for x in 0...24 {
                    let candidate = CGRect(x: bounds.minX + CGFloat(x) / 24 * (bounds.width - size.width),
                                           y: bounds.minY + CGFloat(y) / 20 * (bounds.height - size.height),
                                           width: size.width, height: size.height)
                    let padded = candidate.insetBy(dx: -9, dy: -9)
                    if let obstacle, padded.intersects(obstacle) { continue }
                    if placed.values.contains(where: { padded.intersects($0.insetBy(dx: -9, dy: -9)) }) { continue }
                    let dx = candidate.midX - wanted.x, dy = candidate.midY - wanted.y
                    let score = dx * dx + dy * dy
                    if score < cost { cost = score; best = candidate }
                } }
                guard let best else { break }
                placed[index] = best
            }
            if placed.count == names.count {
                return names.indices.map { index in
                    let frame = placed[index]!
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
