import Foundation
import CoreGraphics

/// Deterministic free-space packing of app clusters. Overlap is reserved for
/// windows within a cluster, never between clusters or the workspace panel.
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
    public struct Group: Equatable, Sendable {
        public var app: String
        public var ids: [UInt32]
        public var frame: CGRect
        public init(app: String, ids: [UInt32], frame: CGRect) { self.app = app; self.ids = ids; self.frame = frame }
    }
    public static func groups(_ items: [Item], in bounds: CGRect, avoiding obstacle: CGRect? = nil) -> [Group] {
        guard !items.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        let grouped = Dictionary(grouping: items, by: \.app)
        let names = grouped.keys.sorted()
        let sources = names.map { name -> CGRect in
            let windows = grouped[name]!
            return CGRect(x: windows.map { $0.source.midX }.reduce(0,+) / CGFloat(windows.count),
                          y: windows.map { $0.source.midY }.reduce(0,+) / CGFloat(windows.count),
                          width: windows.map { max(1, $0.source.width) }.max()!,
                          height: windows.map { max(1, $0.source.height) }.max()!)
        }
        let minX = sources.map(\.minX).min()!, maxX = sources.map(\.minX).max()!
        let minY = sources.map(\.minY).min()!, maxY = sources.map(\.minY).max()!
        // Fixed candidate lattice with spatial scoring is predictable, bounded,
        // and does not impose rows on the final variable-sized cluster frames.
        var solution: [CGRect] = []
        for attempt in 0..<36 {
            let scale = 0.42 * pow(0.90, Double(attempt))
            var placed: [Int: CGRect] = [:]
            for index in sources.indices.sorted(by: {
                let a = sources[$0].width * sources[$0].height, b = sources[$1].width * sources[$1].height
                return a == b ? $0 < $1 : a > b
            }) {
                let source = sources[index]
                let depth = CGFloat(min(3, grouped[names[index]]!.count - 1)) * 14
                let size = CGSize(width: max(112, source.width * scale) + depth,
                                  height: max(64, source.height * scale) + depth + 56)
                guard size.width <= bounds.width, size.height <= bounds.height else { break }
                let wanted = CGPoint(x: bounds.minX + (maxX > minX ? (source.minX - minX) / (maxX - minX) : 0.5) * bounds.width,
                                     y: bounds.minY + (maxY > minY ? (source.minY - minY) / (maxY - minY) : 0.5) * bounds.height)
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
            if placed.count == names.count { solution = names.indices.map { placed[$0]! }; break }
        }
        // Very crowded/small displays retain access through the caller's list fallback.
        guard solution.count == names.count else { return [] }
        return names.indices.map { index in
            let ordered = grouped[names[index]]!.sorted {
                if $0.tabCount != $1.tabCount { return $0.tabCount > $1.tabCount }
                return $0.id < $1.id
            }
            return Group(app: names[index], ids: ordered.map(\.id), frame: solution[index])
        }
    }
}
