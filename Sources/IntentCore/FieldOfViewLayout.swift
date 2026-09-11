import Foundation
import CoreGraphics

/// A bounded, aspect-preserving overview. Cells are only layout guides, never UI cards.
public enum FieldOfViewLayout {
    public static func frames(sizes: [CGSize], in bounds: CGRect, tabHeight: CGFloat = 62) -> [CGRect] {
        guard !sizes.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        let gap: CGFloat = 22
        var best: [CGRect] = []
        var bestScore: CGFloat = -1
        for columns in 1...sizes.count {
            let rows = Int(ceil(Double(sizes.count) / Double(columns)))
            let cellWidth = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let reserved = tabHeight + 26
            guard cellWidth > 8, cellHeight - reserved > 8 else { continue }
            var result: [CGRect] = []
            var score: CGFloat = 0
            for (index, size) in sizes.enumerated() {
                let row = index / columns
                let column = index % columns
                let rowCount = min(columns, sizes.count - row * columns)
                let width: CGFloat = max(1, size.width)
                let height: CGFloat = max(1, size.height)
                let scale: CGFloat = min(min(cellWidth / width, (cellHeight - reserved) / height), 1)
                let fitted = CGSize(width: width * scale, height: height * scale)
                let rowWidth = CGFloat(rowCount) * cellWidth + CGFloat(rowCount - 1) * gap
                let cellX: CGFloat = bounds.midX - rowWidth / 2 + CGFloat(column) * (cellWidth + gap)
                let cellY: CGFloat = bounds.minY + CGFloat(row) * (cellHeight + gap)
                let x: CGFloat = cellX + (cellWidth - fitted.width) / 2
                let y: CGFloat = cellY + tabHeight + (cellHeight - reserved - fitted.height) / 2
                result.append(CGRect(origin: CGPoint(x: x, y: y), size: fitted))
                score += sqrt(fitted.width * fitted.height)
            }
            if score > bestScore { bestScore = score; best = result }
        }
        return best
    }
}

/// Never attach a tab group to a window on a guess. Browser window IDs are not CGWindowIDs.
public enum BrowserWindowMatching {
    public static func match(title: String, tabs: [BrowserTabItem], nativeWindowCount: Int) -> Int? {
        let ids = Set(tabs.map(\.windowID))
        if ids.count == 1, nativeWindowCount == 1 { return ids.first }
        let normalized = normalize(title)
        guard !normalized.isEmpty else { return nil }
        let matching = Set(tabs.filter { $0.active && titleMatches(normalized, normalize($0.title)) }.map(\.windowID))
        return matching.count == 1 ? matching.first : nil
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
