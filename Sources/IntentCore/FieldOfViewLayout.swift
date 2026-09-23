import Foundation
import CoreGraphics

/// A compact overview with one shared preview scale, rather than equal-sized grid cells.
/// Every returned frame is a thumbnail; room for its caption is reserved below it.
public enum FieldOfViewLayout {
    public static let minimumCaptionWidth: CGFloat = 110
    public static let captionHeight: CGFloat = 26
    private static let gap: CGFloat = 18

    public static func frames(sizes: [CGSize], in bounds: CGRect, tabHeight: CGFloat = 62) -> [CGRect] {
        layout(sizes: sizes, sourceFrames: nil, in: bounds, tabHeight: tabHeight)
    }

    /// Source frames use top-left screen coordinates, as reported by CGWindow/ScreenCaptureKit.
    /// Results retain the input indices even when thumbnails move to a different row.
    public static func frames(sourceFrames: [CGRect], in bounds: CGRect, tabHeight: CGFloat = 62) -> [CGRect] {
        layout(sizes: sourceFrames.map(\.size), sourceFrames: sourceFrames, in: bounds, tabHeight: tabHeight)
    }

    /// Reserve a movable panel without covering a preview or its caption.
    public static func workspace(around panel: CGRect, in bounds: CGRect) -> CGRect {
        let obstacle = panel.insetBy(dx: -18, dy: -18).intersection(bounds)
        guard !obstacle.isNull else { return bounds }
        let candidates = [
            CGRect(x: bounds.minX, y: bounds.minY, width: max(0, obstacle.minX - bounds.minX), height: bounds.height),
            CGRect(x: obstacle.maxX, y: bounds.minY, width: max(0, bounds.maxX - obstacle.maxX), height: bounds.height),
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, obstacle.minY - bounds.minY)),
            CGRect(x: bounds.minX, y: obstacle.maxY, width: bounds.width, height: max(0, bounds.maxY - obstacle.maxY))
        ]
        return candidates.max { $0.width * $0.height < $1.width * $1.height } ?? bounds
    }

    public static func panel(origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGRect {
        let width = min(size.width, bounds.width), height = min(size.height, bounds.height)
        return CGRect(x: min(max(bounds.minX, origin.x), bounds.maxX - width),
                      y: min(max(bounds.minY, origin.y), bounds.maxY - height), width: width, height: height)
    }

    /// Use the space on every side of the movable list, retaining one preview
    /// scale. This avoids making all windows tiny when the list is in the middle.
    public static func frames(sourceFrames: [CGRect], in bounds: CGRect, avoiding panel: CGRect) -> [CGRect] {
        guard !sourceFrames.isEmpty else { return [] }
        let obstacle = panel.insetBy(dx: -18, dy: -18).intersection(bounds)
        guard !obstacle.isNull else { return frames(sourceFrames: sourceFrames, in: bounds, tabHeight: 0) }
        let regions = [
            CGRect(x: bounds.minX, y: bounds.minY, width: max(0, obstacle.minX - bounds.minX), height: bounds.height),
            CGRect(x: obstacle.maxX, y: bounds.minY, width: max(0, bounds.maxX - obstacle.maxX), height: bounds.height),
            CGRect(x: obstacle.minX, y: bounds.minY, width: obstacle.width, height: max(0, obstacle.minY - bounds.minY)),
            CGRect(x: obstacle.minX, y: obstacle.maxY, width: obstacle.width, height: max(0, bounds.maxY - obstacle.maxY))
        ].filter { $0.width >= minimumCaptionWidth + 4 && $0.height > captionHeight + 4 }
        var groups = Array(repeating: [Int](), count: regions.count)
        let capacities = regions.map { region in
            Int((region.width - 4 + gap) / (minimumCaptionWidth + gap))
                * Int((region.height - 4 + gap) / (captionHeight + gap))
        }
        // Larger windows get first choice. Capacity checks are constant-time;
        // pack each region once, rather than packing on every pointer movement
        // once per candidate window.
        for index in sourceFrames.indices.sorted(by: { sourceFrames[$0].width * sourceFrames[$0].height > sourceFrames[$1].width * sourceFrames[$1].height }) {
            let candidates = regions.indices.filter { groups[$0].count < capacities[$0] }
            guard let region = candidates.min(by: { left, right in
                let a = CGFloat(groups[left].count + 1) / (regions[left].width * regions[left].height)
                let b = CGFloat(groups[right].count + 1) / (regions[right].width * regions[right].height)
                return a == b ? left < right : a < b
            }) else { return frames(sourceFrames: sourceFrames, in: workspace(around: panel, in: bounds), tabHeight: 0) }
            groups[region].append(index)
        }
        var result = Array(repeating: CGRect.zero, count: sourceFrames.count)
        var scale: CGFloat = 1
        for region in regions.indices {
            let packed = frames(sourceFrames: groups[region].map { sourceFrames[$0] }, in: regions[region], tabHeight: 0)
            guard packed.count == groups[region].count else {
                return frames(sourceFrames: sourceFrames, in: workspace(around: panel, in: bounds), tabHeight: 0)
            }
            for (offset, index) in groups[region].enumerated() {
                result[index] = packed[offset]
                scale = min(scale, packed[offset].width / max(1, sourceFrames[index].width))
            }
        }
        return result.enumerated().map { index, slot in
            let size = CGSize(width: max(1, sourceFrames[index].width) * scale, height: max(1, sourceFrames[index].height) * scale)
            return CGRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    private struct Row {
        let indices: [Int]
        let width: CGFloat
        let height: CGFloat
    }

    private static func layout(sizes: [CGSize], sourceFrames: [CGRect]?, in bounds: CGRect, tabHeight: CGFloat) -> [CGRect] {
        guard !sizes.isEmpty, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 4, bounds.height > 4 else { return [] }
        let area = bounds.insetBy(dx: 2, dy: 2)
        let sizes = sizes.map { CGSize(width: $0.width.isFinite ? max(1, $0.width) : 1,
                                       height: $0.height.isFinite ? max(1, $0.height) : 1) }
        let topReserve = tabHeight.isFinite ? max(0, tabHeight) : 0
        let reserve = topReserve + captionHeight
        let indices = Array(sizes.indices)
        let source = sourceFrames.flatMap { frames in
            frames.allSatisfy { $0.midX.isFinite && $0.midY.isFinite } ? frames : nil
        }
        // Trying a small, fixed collection of orders avoids both the wasted space of
        // equal cells and an unbounded rectangle-packing search on every UI refresh.
        var orders = [indices]
        for dimension in 0...2 {
            orders.append(indices.sorted { left, right in
                let a = dimension == 0 ? sizes[left].height : (dimension == 1 ? sizes[left].width : sizes[left].width * sizes[left].height)
                let b = dimension == 0 ? sizes[right].height : (dimension == 1 ? sizes[right].width : sizes[right].width * sizes[right].height)
                return a == b ? left < right : a > b
            })
        }
        if let source {
            let minY = source.map(\.midY).min() ?? 0
            let spanY = max(1, (source.map(\.midY).max() ?? 0) - minY)
            for bands in [1, 2, 3, 4, 6, 8] {
                orders.append(indices.sorted { left, right in
                    let leftBand = Int((source[left].midY - minY) / spanY * CGFloat(bands))
                    let rightBand = Int((source[right].midY - minY) / spanY * CGFloat(bands))
                    if leftBand != rightBand { return leftBand < rightBand }
                    if source[left].midX != source[right].midX { return source[left].midX < source[right].midX }
                    if source[left].midY != source[right].midY { return source[left].midY < source[right].midY }
                    return left < right
                })
            }
        }
        var uniqueOrders: [[Int]] = []
        for order in orders where !uniqueOrders.contains(order) { uniqueOrders.append(order) }
        var candidates: [(scale: CGFloat, frames: [CGRect], travel: CGFloat)] = []
        for order in uniqueOrders {
            guard rows(order: order, sizes: sizes, scale: 0, width: area.width, reserve: reserve)?.height ?? .infinity <= area.height else { continue }
            var lower: CGFloat = 0
            var upper: CGFloat = 1 // Never enlarge a tiny real window beyond its native size.
            for _ in 0..<22 {
                let scale = (lower + upper) / 2
                if let packed = rows(order: order, sizes: sizes, scale: scale, width: area.width, reserve: reserve), packed.height <= area.height {
                    lower = scale
                } else {
                    upper = scale
                }
            }
            guard lower > 0, let packed = rows(order: order, sizes: sizes, scale: lower, width: area.width, reserve: reserve) else { continue }
            var arranged = packed.rows
            if let source {
                // These changes do not alter row dimensions, so spatial familiarity
                // never trades away the collision/bounds guarantees of packing.
                arranged = arranged.map { row in
                    Row(indices: row.indices.sorted {
                        source[$0].midX == source[$1].midX ? $0 < $1 : source[$0].midX < source[$1].midX
                    }, width: row.width, height: row.height)
                }.sorted { left, right in
                    let leftY = left.indices.reduce(CGFloat.zero) { $0 + source[$1].midY } / CGFloat(left.indices.count)
                    let rightY = right.indices.reduce(CGFloat.zero) { $0 + source[$1].midY } / CGFloat(right.indices.count)
                    return leftY == rightY ? (left.indices.min() ?? 0) < (right.indices.min() ?? 0) : leftY < rightY
                }
            }
            var frames = Array(repeating: CGRect.zero, count: sizes.count)
            var y = area.midY - packed.height / 2
            for row in arranged {
                var x = area.midX - row.width / 2
                for index in row.indices {
                    let size = CGSize(width: sizes[index].width * lower, height: sizes[index].height * lower)
                    let cardWidth = max(minimumCaptionWidth, size.width)
                    frames[index] = CGRect(x: x + (cardWidth - size.width) / 2,
                                           y: y + topReserve + (row.height - reserve - size.height) / 2,
                                           width: size.width, height: size.height)
                    x += cardWidth + gap
                }
                y += row.height + gap
            }
            let travel: CGFloat = source.map { source in
                let minX = source.map(\.midX).min() ?? 0, maxX = source.map(\.midX).max() ?? 0
                let minY = source.map(\.midY).min() ?? 0, maxY = source.map(\.midY).max() ?? 0
                return indices.reduce(CGFloat.zero) { result, index in
                    let wantedX = maxX > minX ? (source[index].midX - minX) / (maxX - minX) : 0.5
                    let wantedY = maxY > minY ? (source[index].midY - minY) / (maxY - minY) : 0.5
                    let dx = (frames[index].midX - area.minX) / area.width - wantedX
                    let dy = (frames[index].midY - area.minY) / area.height - wantedY
                    return result + dx * dx + dy * dy
                }
            } ?? 0
            candidates.append((lower, frames, travel))
        }
        guard let largest = candidates.map(\.scale).max() else { return [] }
        // A half-percent scale tolerance favors a familiar arrangement when two
        // packs are visually the same size, without returning to a sparse grid.
        return candidates.filter { $0.scale >= largest * 0.995 }.min { left, right in
            if left.travel != right.travel { return left.travel < right.travel }
            return left.scale > right.scale
        }?.frames ?? []
    }

    /// For one order/scale, find the shortest stack of variable-width rows.
    /// Dynamic programming allows short windows to share space beside wider ones.
    private static func rows(order: [Int], sizes: [CGSize], scale: CGFloat, width: CGFloat, reserve: CGFloat) -> (rows: [Row], height: CGFloat)? {
        var heights = Array(repeating: CGFloat.infinity, count: order.count + 1)
        var previous = Array(repeating: -1, count: order.count + 1)
        heights[0] = 0
        for end in 1...order.count {
            var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
            for start in stride(from: end - 1, through: 0, by: -1) {
                let size = sizes[order[start]]
                rowWidth += max(minimumCaptionWidth, size.width * scale) + (start == end - 1 ? 0 : gap)
                if rowWidth > width { break }
                rowHeight = max(rowHeight, size.height * scale + reserve)
                let candidate = heights[start] + (start == 0 ? 0 : gap) + rowHeight
                if candidate < heights[end] {
                    heights[end] = candidate
                    previous[end] = start
                }
            }
        }
        guard heights[order.count].isFinite else { return nil }
        var result: [Row] = []
        var end = order.count
        while end > 0 {
            let start = previous[end]
            guard start >= 0 else { return nil }
            let members = Array(order[start..<end])
            let rowWidth = members.reduce(CGFloat.zero) { $0 + max(minimumCaptionWidth, sizes[$1].width * scale) } + CGFloat(members.count - 1) * gap
            let rowHeight = members.map { sizes[$0].height * scale + reserve }.max() ?? reserve
            result.append(Row(indices: members, width: rowWidth, height: rowHeight))
            end = start
        }
        return (result.reversed(), heights[order.count])
    }
}

/// Never attach a tab group to a window on a guess. Browser window IDs are not CGWindowIDs.
public enum BrowserWindowMatching {
    public static func match(title: String, tabs: [BrowserTabItem], nativeWindowCount: Int, frame: CGRect? = nil, isFocused: Bool = false) -> Int? {
        let normalized = normalize(title)
        let titled = Set(tabs.filter { $0.active && !normalized.isEmpty && titleMatches(normalized, normalize($0.title)) }.map(\.windowID))
        // Titles distinguish equally sized windows (and disconnected profiles).
        // Geometry may break a title tie, but must never override a known title.
        if titled.count == 1 { return titled.first }
        // During a page-title change, fresh browser focus plus exact geometry
        // identifies the foreground window without borrowing a background profile.
        if isFocused, titled.isEmpty, let frame {
            let focused = Set(tabs.filter { tab in
                guard tab.windowFocused == true, let candidate = tab.windowFrame?.rect else { return false }
                return abs(candidate.minX - frame.minX) <= 3 && abs(candidate.minY - frame.minY) <= 3
                    && abs(candidate.width - frame.width) <= 3 && abs(candidate.height - frame.height) <= 3
            }.map(\.windowID))
            if focused.count == 1 { return focused.first }
        }
        let candidates = normalized.isEmpty ? tabs : tabs.filter { titled.contains($0.windowID) }
        if let frame, frame.width > 0, frame.height > 0 {
            let geometryMatches = Set(candidates.filter { tab in
                guard let candidate = tab.windowFrame?.rect else { return false }
                return abs(candidate.minX - frame.minX) <= 3 && abs(candidate.minY - frame.minY) <= 3
                    && abs(candidate.width - frame.width) <= 3 && abs(candidate.height - frame.height) <= 3
            }.map(\.windowID))
            if geometryMatches.count == 1 { return geometryMatches.first }
            if isFocused {
                let focused = Set(candidates.filter { $0.windowFocused == true && geometryMatches.contains($0.windowID) }.map(\.windowID))
                if focused.count == 1 { return focused.first }
            }
        }
        if normalized.isEmpty {
            let ids = Set(tabs.map(\.windowID))
            if ids.count == 1, nativeWindowCount == 1 { return ids.first }
        }
        return nil
    }

    public static func sameWindowTitle(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalize(lhs), right = normalize(rhs)
        return !left.isEmpty && !right.isEmpty && (titleMatches(left, right) || titleMatches(right, left))
    }

    private static func titleMatches(_ native: String, _ tab: String) -> Bool {
        if native == tab { return true }
        // macOS can truncate a browser's window title even when the tab title is complete.
        // Require both visible ends and retain the unique-candidate check above.
        let parts = native.components(separatedBy: "…")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return tab.hasPrefix(parts[0]) && tab.hasSuffix(parts[1])
    }

    private static func normalize(_ title: String) -> String {
        var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Chrome's AX window title may include its profile after the browser name.
        // Without this, multi-window mapping fails even though every tab is present.
        for marker in [" — Google Chrome – ", " - Google Chrome – "] {
            if let range = value.range(of: marker, options: .backwards), !value[range.upperBound...].isEmpty {
                value = String(value[..<range.lowerBound])
                break
            }
        }
        for suffix in [" — Mozilla Firefox", " - Mozilla Firefox", " — Google Chrome", " - Google Chrome"] {
            if value.hasSuffix(suffix) { value.removeLast(suffix.count) }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
