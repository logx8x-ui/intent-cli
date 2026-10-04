import Foundation

/// A single active occurrence's discovery reader. Historical files retain only
/// metadata, not decoded window titles/plans. Directory discovery remains linear
/// in file count, but unchanged refreshes perform no historical JSON decoding.
/// Confine an instance to its caller's serial queue.
public final class BrowserWindowVisibilityRecordCache {
    private struct Stamp: Equatable {
        var modified: Date
        var size: UInt64
        var inode: UInt64
        var device: UInt64
    }
    private struct Cached {
        var stamp: Stamp
        var record: BrowserWindowVisibilityRecord?
    }
    private let store: BrowserWindowVisibilityStore
    private let intentionSessionID: String
    private let readData: (URL) throws -> Data
    private var cached: [URL: Cached] = [:]

    public init(store: BrowserWindowVisibilityStore = .init(), intentionSessionID: String,
                readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.store = store
        self.intentionSessionID = intentionSessionID
        self.readData = readData
    }

    /// Always discovers new/removed files. Finish additionally revalidates the
    /// cached current occurrence, without re-decoding unchanged old history.
    /// I/O uncertainty never returns the old value as new-claim authority and is
    /// retried on the next call; only successfully read invalid bytes are cached.
    public func records(forceRefresh: Bool = false) -> [BrowserWindowVisibilityRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: store.directory,
            includingPropertiesForKeys: nil) else { return [] }
        var next: [URL: Cached] = [:]
        for file in files where file.pathExtension == "json"
            && file.lastPathComponent.hasPrefix("browser-window-visibility-") {
            guard let before = stamp(file) else { continue }
            if let previous = cached[file], previous.stamp == before,
               !forceRefresh || previous.record == nil {
                next[file] = previous
                continue
            }
            guard before.size <= UInt64(BrowserWindowVisibilityStore.maximumFileBytes) else {
                next[file] = Cached(stamp: before, record: nil)
                continue
            }
            guard let data = try? readData(file), let after = stamp(file), before == after else { continue }
            let record: BrowserWindowVisibilityRecord?
            if data.count <= BrowserWindowVisibilityStore.maximumFileBytes,
               let decoded = try? JSONDecoder().decode(BrowserWindowVisibilityRecord.self, from: data), decoded.isValid,
               store.fileURL(browserBundleIdentifier: decoded.browserBundleIdentifier,
                   browserSessionID: decoded.browserSessionID, intentionSessionID: decoded.plan.intentionSessionID).standardizedFileURL
                    == file.standardizedFileURL,
               decoded.plan.intentionSessionID == intentionSessionID {
                record = decoded
            } else {
                record = nil
            }
            next[file] = Cached(stamp: after, record: record)
        }
        cached = next
        return next.values.compactMap(\.record).sorted {
            ($0.browserBundleIdentifier, $0.browserSessionID) < ($1.browserBundleIdentifier, $1.browserSessionID)
        }
    }

    private func stamp(_ file: URL) -> Stamp? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: file.path),
              values[.type] as? FileAttributeType == .typeRegular,
              let modified = values[.modificationDate] as? Date,
              let size = values[.size] as? NSNumber,
              let inode = values[.systemFileNumber] as? NSNumber,
              let device = values[.systemNumber] as? NSNumber else { return nil }
        // Atomic replacement can preserve both size and modification time. The
        // filesystem identity is therefore part of the invalidation key too.
        return Stamp(modified: modified, size: size.uint64Value,
            inode: inode.uint64Value, device: device.uint64Value)
    }
}
