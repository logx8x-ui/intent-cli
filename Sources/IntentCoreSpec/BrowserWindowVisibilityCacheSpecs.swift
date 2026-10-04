import Foundation
import IntentCore

func runBrowserWindowVisibilityCacheSpecs() throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("intent-visibility-cache-spec-\(UUID().uuidString)")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let store = BrowserWindowVisibilityStore(directory: directory)
    let browser = "org.mozilla.firefox"
    let session = "current-intention"
    let timestamp = Date(timeIntervalSinceReferenceDate: 1_000)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    func makeRecord(_ profile: String, intention: String = "current-intention", title: String = "Alpha") -> BrowserWindowVisibilityRecord {
        let window = BrowserWindowVisibilityWindow(windowID: 7, title: title,
            frame: .init(left: 10, top: 30, width: 800, height: 600), state: "normal")
        return .init(browserBundleIdentifier: browser, browserSessionID: profile, receivedAt: timestamp,
            plan: .init(intentionSessionID: intention, revision: 1, windows: [window]))
    }
    func file(_ record: BrowserWindowVisibilityRecord) -> URL {
        store.fileURL(browserBundleIdentifier: record.browserBundleIdentifier, browserSessionID: record.browserSessionID,
            intentionSessionID: record.plan.intentionSessionID).standardizedFileURL
    }
    func write(_ record: BrowserWindowVisibilityRecord) throws {
        try encoder.encode(record).write(to: file(record), options: .atomic)
    }
    let current = makeRecord("profile-a")
    try write(current)
    // Whole seconds round-trip exactly through Foundation's timestamp setter;
    // a generated subsecond date can otherwise round while setting the fixture.
    try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
        ofItemAtPath: file(current).path)
    let historical = (0..<12).map { makeRecord("profile-a", intention: "old-intention-\($0)") }
    for record in historical { try write(record) }

    var reads: [URL: Int] = [:]
    var failReads: Set<URL> = []
    let cache = BrowserWindowVisibilityRecordCache(store: store, intentionSessionID: session) { url in
        // Foundation's enumerated URLs and constructed temp-directory URLs can
        // differ as raw keys despite naming the same standardized file.
        let key = url.standardizedFileURL
        reads[key, default: 0] += 1
        if failReads.contains(key) { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }
    try expect(cache.records() == [current], "Discovery returns only the current occurrence, not historical ownership")
    try expect(reads.values.reduce(0, +) == 13, "The initial discovery reads each candidate once")
    for _ in 0..<10 {
        try expect(cache.records() == [current], "An unchanged snapshot keeps its exact current plan")
    }
    try expect(reads.values.reduce(0, +) == 13, "Unchanged active refreshes do not read or decode historical or current JSON again")
    let forcedSnapshot = cache.records(forceRefresh: true)
    try expect(forcedSnapshot == [current] && reads[file(current)] == 2,
        "Finish forces a fresh current-occurrence read (snapshot=\(forcedSnapshot == [current]), reads=\(reads[file(current)] ?? -1))")
    try expect(historical.allSatisfy { reads[file($0)] == 1 },
        "Forced finish discovery does not re-decode unchanged historical occurrences")

    let before = try manager.attributesOfItem(atPath: file(current).path)
    var replacement = current
    replacement.plan.windows[0].title = "Bravo"
    let beforeData = try encoder.encode(current)
    let replacementData = try encoder.encode(replacement)
    try expect(beforeData.count == replacementData.count, "Atomic replacement fixture preserves the file's byte count")
    try replacementData.write(to: file(current), options: .atomic)
    try manager.setAttributes([.modificationDate: before[.modificationDate]!], ofItemAtPath: file(current).path)
    let after = try manager.attributesOfItem(atPath: file(current).path)
    try expect(before[.systemFileNumber] as? NSNumber != after[.systemFileNumber] as? NSNumber,
        "The replacement fixture has a different inode")
    try expect(before[.size] as? NSNumber == after[.size] as? NSNumber
        && before[.modificationDate] as? Date == after[.modificationDate] as? Date,
        "The replacement fixture keeps the same size and modification timestamp")
    try expect(cache.records() == [replacement] && reads[file(current)] == 3,
        "A same-size, same-mtime atomic replacement invalidates the cache by filesystem identity")

    let newProfile = makeRecord("profile-b")
    try write(newProfile)
    try expect(cache.records() == [replacement, newProfile] && reads[file(newProfile)] == 1,
        "A new browser profile is discovered during the active occurrence")
    try expect(historical.allSatisfy { reads[file($0)] == 1 },
        "A new profile does not force historical plans to be decoded again")

    let repaired = makeRecord("profile-c")
    try Data("not valid JSON".utf8).write(to: file(repaired), options: .atomic)
    try expect(cache.records() == [replacement, newProfile], "Invalid bytes cannot authorize a window claim")
    _ = cache.records()
    try expect(reads[file(repaired)] == 1, "Stable known-invalid bytes are not repeatedly decoded")
    try write(repaired)
    try expect(cache.records() == [replacement, newProfile, repaired] && reads[file(repaired)] == 2,
        "Invalid-to-valid atomic replacement is retried and accepted")

    let initiallyUnreadable = makeRecord("profile-d")
    try write(initiallyUnreadable)
    failReads.insert(file(initiallyUnreadable))
    try expect(!cache.records().contains(initiallyUnreadable) && reads[file(initiallyUnreadable)] == 1,
        "A failed first read cannot introduce a new native claim")
    failReads.remove(file(initiallyUnreadable))
    try expect(cache.records().contains(initiallyUnreadable) && reads[file(initiallyUnreadable)] == 2,
        "A transient read failure retries even when metadata is unchanged")

    failReads.insert(file(current))
    let previousReads = reads[file(current), default: 0]
    try expect(!cache.records(forceRefresh: true).contains(replacement),
        "A failed forced read never returns its previously cached plan as authority")
    failReads.remove(file(current))
    try expect(cache.records().contains(replacement) && reads[file(current)] == previousReads + 2,
        "An unreadable previously cached plan is retried without a permanent failure tombstone")

    let hiddenDirectory = directory.appendingPathExtension("unavailable")
    try manager.moveItem(at: directory, to: hiddenDirectory)
    let unavailableSnapshot = cache.records()
    try manager.moveItem(at: hiddenDirectory, to: directory)
    try expect(unavailableSnapshot.isEmpty, "A directory listing failure returns no stale new-claim authority")
    try expect(cache.records().contains(replacement), "Discovery retries after the directory becomes available again")

    try manager.removeItem(at: file(newProfile))
    try expect(!cache.records().contains(newProfile), "Removing a plan prunes it from the next current snapshot")
    try expect(historical.allSatisfy { manager.fileExists(atPath: file($0).path) },
        "Cache pruning never deletes durable recovery history")
    try expect(store.record(browserBundleIdentifier: browser, browserSessionID: historical[0].browserSessionID,
        intentionSessionID: historical[0].plan.intentionSessionID) == historical[0],
        "Recovery directly reads a historical journal tuple without current-scope filtering")
    try expect(store.record(browserBundleIdentifier: browser, browserSessionID: "missing-profile", intentionSessionID: session) == nil,
        "A missing exact tuple cannot fall back to a different profile")

    let forged = makeRecord("different-profile")
    try encoder.encode(forged).write(to: file(current), options: .atomic)
    try expect(store.record(browserBundleIdentifier: browser, browserSessionID: current.browserSessionID,
        intentionSessionID: session) == nil, "Direct recovery reads reject mismatched persisted tuple identity")
    try expect(!cache.records().contains(forged) && !cache.records().contains(replacement),
        "Discovery validates the canonical hashed path and cannot keep the replaced prior plan")
}
