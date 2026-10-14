import CoreGraphics
import Foundation
import IntentCore

/// Pure parsing and matching for native window identity. Permissive geometry is
/// only for binding one positive-size target, never for declaring coverage.
public enum NativeWindowBindingInventory {
    /// Nil means unknown, including a target missing from the complete lifetime
    /// inventory. False is a positive visible observation, never a minimize flag.
    /// No AX omission or preview-size filter supplies offscreen evidence.
    public static func isOffscreen(windowID: UInt32, pid: Int32,
                                   allRows: [[String: Any]]?, onScreenRows: [[String: Any]]?) -> Bool? {
        guard windowID > 0, pid > 0, let allRows, let onScreenRows,
              serverIdentitiesAreComplete(in: allRows), serverIdentitiesAreComplete(in: onScreenRows),
              allRows.contains(where: { $0[kCGWindowNumber as String] as? UInt32 == windowID
                  && $0[kCGWindowOwnerPID as String] as? Int32 == pid
                  && $0[kCGWindowLayer as String] as? Int == 0 }) else { return nil }
        if let visible = onScreenRows.first(where: { $0[kCGWindowNumber as String] as? UInt32 == windowID }) {
            return visible[kCGWindowOwnerPID as String] as? Int32 == pid ? false : nil
        }
        return true
    }

    public static func serverIdentitiesAreComplete(in rows: [[String: Any]]) -> Bool {
        var identities: [(pid: Int32, windowID: UInt32)] = []
        for row in rows {
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32 else { return false }
            identities.append((pid: pid, windowID: id))
        }
        return NativeVisibilityCoveragePolicy.serverIdentitiesAreComplete(identities)
    }

    public static func windows(rows: [[String: Any]], pid: Int32, bundleIdentifier: String,
                               requireUsableGeometry: Bool = true) -> [WorkspaceWindow]? {
        guard pid > 0, !bundleIdentifier.isEmpty, serverIdentitiesAreComplete(in: rows) else { return nil }
        var result: [WorkspaceWindow] = []
        for row in rows where row[kCGWindowOwnerPID as String] as? Int32 == pid {
            guard let layer = row[kCGWindowLayer as String] as? Int else { return nil }
            guard layer == 0 else { continue }
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = validatedFrame(bounds),
                  !requireUsableGeometry || hasUsableGeometry(frame) else { return nil }
            // Keep zero-area siblings: they can still make a tiny target's
            // reverse match ambiguous within the existing three-point tolerance.
            result.append(.init(id: id, pid: pid, bundle: bundleIdentifier,
                title: row[kCGWindowName as String] as? String ?? "", frame: frame))
        }
        return result
    }

    private static func validatedFrame(_ bounds: [String: Any]) -> CGRect? {
        // CGRect's CF dictionary initializer can message an invalid value as
        // NSNumber rather than reject it. Validate each CF number ourselves;
        // CFBoolean also bridges to NSNumber but is not geometry.
        var values: [CGFloat] = []
        for key in ["X", "Y", "Width", "Height"] {
            guard let number = bounds[key] as? NSNumber,
                  CFGetTypeID(number) == CFNumberGetTypeID(), number.doubleValue.isFinite else { return nil }
            values.append(CGFloat(number.doubleValue))
        }
        guard values[2] >= 0, values[3] >= 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    public static func hasUsableGeometry(_ frame: CGRect) -> Bool {
        NativeVisibilityCoveragePolicy.usableOwnedWindowGeometry(x: Double(frame.origin.x),
            y: Double(frame.origin.y), width: Double(frame.size.width), height: Double(frame.size.height))
    }

    public static func uniquelyMatches(target: WorkspaceWindow, accessibilityTitle: String,
                                       accessibilityFrame: CGRect, native: [WorkspaceWindow],
                                       sameTitle: (String, String) -> Bool) -> Bool {
        guard hasUsableGeometry(target.frame), hasUsableGeometry(accessibilityFrame),
              sameTitle(accessibilityTitle, target.title), sameFrame(accessibilityFrame, target.frame) else { return false }
        let currentTarget = native.filter { $0.pid == target.pid && $0.bundle == target.bundle && $0.id == target.id }
        guard currentTarget.count == 1, hasUsableGeometry(currentTarget[0].frame) else { return false }
        let counterparts = native.filter {
            $0.pid == target.pid && $0.bundle == target.bundle
                && sameTitle(accessibilityTitle, $0.title) && sameFrame(accessibilityFrame, $0.frame)
        }
        return counterparts.count == 1 && counterparts[0].id == target.id
    }

    private static func sameFrame(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) <= 3 && abs(first.minY - second.minY) <= 3
            && abs(first.width - second.width) <= 3 && abs(first.height - second.height) <= 3
    }
}
