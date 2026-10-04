import Foundation
import Darwin

/// Process lifetime proof is supplied by the native host, never trusted from JS.
/// launched uses Foundation seconds since 2001, matching NSRunningApplication.
public struct BrowserProcessIdentity: Codable, Equatable {
    public var pid: Int32
    public var launched: Double

    public init(pid: Int32, launched: Double) {
        self.pid = pid; self.launched = launched
    }

    public var isValid: Bool { pid > 0 && launched.isFinite }
}

/// Browser window numbers are profile-local and are never native WindowServer IDs.
public struct BrowserWindowVisibilityWindow: Codable, Equatable {
    public var windowID: Int
    public var title: String
    public var frame: BrowserWindowFrame
    public var state: String

    public init(windowID: Int, title: String, frame: BrowserWindowFrame, state: String) {
        self.windowID = windowID; self.title = title; self.frame = frame; self.state = state
    }

    public var isValid: Bool {
        windowID >= 0 && windowID <= 9_007_199_254_740_991 && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.utf8.count <= 4096 && Self.validFrame(frame.rect)
            && ["normal", "minimized", "maximized", "fullscreen"].contains(state)
    }

    fileprivate static func validFrame(_ frame: CGRect) -> Bool {
        let values = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        return values.allSatisfy(\.isFinite) && abs(frame.origin.x) <= 100_000
            && abs(frame.origin.y) <= 100_000 && frame.size.width > 0 && frame.size.width <= 100_000
            && frame.size.height > 0 && frame.size.height <= 100_000
    }
}

public struct BrowserWindowVisibilityPlan: Codable, Equatable {
    public var intentionSessionID: String
    public var revision: Int
    public var windows: [BrowserWindowVisibilityWindow]
    public var parkingWindows: [BrowserWindowVisibilityWindow]
    public var revealWindowIDs: [Int]

    public init(intentionSessionID: String, revision: Int, windows: [BrowserWindowVisibilityWindow],
                parkingWindows: [BrowserWindowVisibilityWindow] = [], revealWindowIDs: [Int] = []) {
        self.intentionSessionID = intentionSessionID; self.revision = revision; self.windows = windows
        self.parkingWindows = parkingWindows; self.revealWindowIDs = revealWindowIDs
    }

    private enum CodingKeys: String, CodingKey { case intentionSessionID, revision, windows, parkingWindows, revealWindowIDs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        intentionSessionID = try values.decode(String.self, forKey: .intentionSessionID)
        revision = try values.decode(Int.self, forKey: .revision)
        windows = try values.decode([BrowserWindowVisibilityWindow].self, forKey: .windows)
        parkingWindows = try values.decodeIfPresent([BrowserWindowVisibilityWindow].self, forKey: .parkingWindows) ?? []
        revealWindowIDs = try values.decodeIfPresent([Int].self, forKey: .revealWindowIDs) ?? []
    }

    public var isValid: Bool {
        let allWindows = windows + parkingWindows
        return validVisibilityIdentity(intentionSessionID) && revision >= 0 && revision <= 9_007_199_254_740_991 && allWindows.count <= 256
            && allWindows.allSatisfy(\.isValid) && Set(allWindows.map(\.windowID)).count == allWindows.count
            && Set(revealWindowIDs).count == revealWindowIDs.count
            && Set(revealWindowIDs).isSubset(of: Set(parkingWindows.map(\.windowID)))
    }
}

public struct BrowserWindowVisibilityRecord: Codable, Equatable {
    public var browserBundleIdentifier: String
    public var browserSessionID: String
    public var receivedAt: Date
    public var plan: BrowserWindowVisibilityPlan
    public var browserProcessIdentity: BrowserProcessIdentity?
    /// First registration survives later desired-plan omissions or title changes.
    public var registeredParkingWindows: [BrowserWindowVisibilityWindow]
    /// A later plan must never retract an already accepted completion reveal.
    public var requestedRevealWindowIDs: [Int]

    public init(browserBundleIdentifier: String, browserSessionID: String, receivedAt: Date = Date(),
                plan: BrowserWindowVisibilityPlan, registeredParkingWindows: [BrowserWindowVisibilityWindow]? = nil,
                requestedRevealWindowIDs: [Int]? = nil, browserProcessIdentity: BrowserProcessIdentity? = nil) {
        self.browserBundleIdentifier = browserBundleIdentifier; self.browserSessionID = browserSessionID
        self.receivedAt = receivedAt; self.plan = plan
        self.registeredParkingWindows = registeredParkingWindows ?? plan.parkingWindows
        self.requestedRevealWindowIDs = requestedRevealWindowIDs ?? plan.revealWindowIDs
        self.browserProcessIdentity = browserProcessIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case browserBundleIdentifier, browserSessionID, receivedAt, plan, registeredParkingWindows, requestedRevealWindowIDs, browserProcessIdentity
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        browserBundleIdentifier = try values.decode(String.self, forKey: .browserBundleIdentifier)
        browserSessionID = try values.decode(String.self, forKey: .browserSessionID)
        receivedAt = try values.decode(Date.self, forKey: .receivedAt)
        plan = try values.decode(BrowserWindowVisibilityPlan.self, forKey: .plan)
        registeredParkingWindows = try values.decodeIfPresent([BrowserWindowVisibilityWindow].self, forKey: .registeredParkingWindows) ?? plan.parkingWindows
        requestedRevealWindowIDs = try values.decodeIfPresent([Int].self, forKey: .requestedRevealWindowIDs) ?? plan.revealWindowIDs
        browserProcessIdentity = try values.decodeIfPresent(BrowserProcessIdentity.self, forKey: .browserProcessIdentity)
    }

    public var isValid: Bool {
        validVisibilityBundle(browserBundleIdentifier) && validVisibilityIdentity(browserSessionID)
            && receivedAt.timeIntervalSinceReferenceDate.isFinite && plan.isValid
            && (browserProcessIdentity.map { $0.isValid && $0.launched <= receivedAt.timeIntervalSinceReferenceDate } ?? true)
            && registeredParkingWindows.count <= 1024 && registeredParkingWindows.allSatisfy(\.isValid)
            && Set(registeredParkingWindows.map(\.windowID)).count == registeredParkingWindows.count
            && Set(requestedRevealWindowIDs).count == requestedRevealWindowIDs.count
            && Set(requestedRevealWindowIDs).isSubset(of: Set(registeredParkingWindows.map(\.windowID)))
            && Set(plan.parkingWindows.map(\.windowID)).isSubset(of: Set(registeredParkingWindows.map(\.windowID)))
            && Set(plan.revealWindowIDs).isSubset(of: Set(requestedRevealWindowIDs))
    }
}

/// Confirms durable native identity capture, not successful AX restoration.
public struct BrowserWindowVisibilityCaptureReceipt: Codable, Equatable {
    public var browserBundleIdentifier: String
    public var browserSessionID: String
    public var intentionSessionID: String
    public var windowIDs: [Int]

    public init(browserBundleIdentifier: String, browserSessionID: String, intentionSessionID: String, windowIDs: [Int]) {
        self.browserBundleIdentifier = browserBundleIdentifier; self.browserSessionID = browserSessionID
        self.intentionSessionID = intentionSessionID; self.windowIDs = windowIDs
    }

    public var isValid: Bool {
        validVisibilityBundle(browserBundleIdentifier) && validVisibilityIdentity(browserSessionID)
            && validVisibilityIdentity(intentionSessionID) && windowIDs.count <= 1024 && Set(windowIDs).count == windowIDs.count
            && windowIDs.allSatisfy { $0 >= 0 && $0 <= 9_007_199_254_740_991 }
    }
}

/// Per-profile/intention file locking serializes overlapping host writers. The
/// caller supplies the current active rules' intention ID, not the request's ID.
public final class BrowserWindowVisibilityStore {
    public enum Acceptance: Equatable { case written, unchanged, rejected }
    public let directory: URL
    static let maximumFileBytes = 2_000_000

    public init(directory: URL? = nil) {
        self.directory = directory ?? ActiveBrowserRulesStore.defaultFileURL().deletingLastPathComponent()
    }

    public func fileURL(browserBundleIdentifier: String, browserSessionID: String, intentionSessionID: String) -> URL {
        // Length-prefix the first identity so even unusual separators in an ID
        // cannot alias a different profile/intention pair.
        let identity = "\(browserSessionID.utf8.count):\(browserSessionID)\(intentionSessionID)"
        return BrowserProfileSnapshots.partition(baseFileURL(browserBundleIdentifier: browserBundleIdentifier), session: identity)
    }

    public func captureReceiptFileURL(browserBundleIdentifier: String, browserSessionID: String, intentionSessionID: String) -> URL {
        fileURL(browserBundleIdentifier: browserBundleIdentifier, browserSessionID: browserSessionID,
            intentionSessionID: intentionSessionID).appendingPathExtension("capture")
    }

    public func capturedWindowIDs(for record: BrowserWindowVisibilityRecord) -> Set<Int> {
        guard record.isValid else { return [] }
        let file = captureReceiptFileURL(browserBundleIdentifier: record.browserBundleIdentifier,
            browserSessionID: record.browserSessionID, intentionSessionID: record.plan.intentionSessionID)
        guard let data = limitedData(file), let receipt = try? JSONDecoder().decode(BrowserWindowVisibilityCaptureReceipt.self, from: data),
              receipt.isValid, receipt.browserBundleIdentifier == record.browserBundleIdentifier,
              receipt.browserSessionID == record.browserSessionID, receipt.intentionSessionID == record.plan.intentionSessionID,
              Set(receipt.windowIDs).isSubset(of: Set(record.registeredParkingWindows.map(\.windowID))) else { return [] }
        return Set(receipt.windowIDs)
    }

    public func capturedWindowIDs(browserBundleIdentifier: String, browserSessionID: String, intentionSessionID: String) -> Set<Int> {
        let file = fileURL(browserBundleIdentifier: browserBundleIdentifier, browserSessionID: browserSessionID,
            intentionSessionID: intentionSessionID)
        guard let record = read(file), record.browserBundleIdentifier == browserBundleIdentifier,
              record.browserSessionID == browserSessionID, record.plan.intentionSessionID == intentionSessionID else { return [] }
        return capturedWindowIDs(for: record)
    }

    /// Call only after the native recovery ledger durably binds these parking
    /// IDs to CG window ID + PID + process launch identity. Captures accumulate.
    @discardableResult
    public func writeCaptureReceipt(_ receipt: BrowserWindowVisibilityCaptureReceipt) throws -> Bool {
        guard receipt.isValid else { return false }
        let file = fileURL(browserBundleIdentifier: receipt.browserBundleIdentifier, browserSessionID: receipt.browserSessionID,
            intentionSessionID: receipt.intentionSessionID)
        return try withFileLock(file) {
            guard let record = read(file), record.browserBundleIdentifier == receipt.browserBundleIdentifier,
                  record.browserSessionID == receipt.browserSessionID, record.plan.intentionSessionID == receipt.intentionSessionID,
                  Set(receipt.windowIDs).isSubset(of: Set(record.registeredParkingWindows.map(\.windowID))) else { return false }
            let alreadyCaptured = capturedWindowIDs(for: record)
            if Set(receipt.windowIDs).isSubset(of: alreadyCaptured) { return true }
            var combined = receipt
            combined.windowIDs = Set(receipt.windowIDs).union(alreadyCaptured).sorted()
            let data = try JSONEncoder().encode(combined)
            guard data.count <= Self.maximumFileBytes else { return false }
            let captureFile = captureReceiptFileURL(browserBundleIdentifier: receipt.browserBundleIdentifier,
                browserSessionID: receipt.browserSessionID, intentionSessionID: receipt.intentionSessionID)
            try data.write(to: captureFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: captureFile.path)
            return true
        }
    }

    /// An equal revision is idempotent only when its payload is identical. A new
    /// intention may reset revisions only while it is the caller's current one.
    @discardableResult
    public func accept(_ plan: BrowserWindowVisibilityPlan, browserBundleIdentifier: String,
                       browserSessionID: String, currentIntentionSessionID: String?,
                       receivedAt: Date = Date(), browserProcessIdentity: BrowserProcessIdentity? = nil) throws -> Acceptance {
        let record = BrowserWindowVisibilityRecord(browserBundleIdentifier: browserBundleIdentifier,
            browserSessionID: browserSessionID, receivedAt: receivedAt, plan: plan, browserProcessIdentity: browserProcessIdentity)
        guard record.isValid, plan.intentionSessionID == currentIntentionSessionID else { return .rejected }
        return try persist(record, revealOnly: false)
    }

    /// Recovery may outlive its intention, including during a newer intention.
    /// A reveal cannot register a window or change previously accepted metadata;
    /// callers must never interpret this as permission to minimize old windows.
    @discardableResult
    public func acceptReveal(_ plan: BrowserWindowVisibilityPlan, browserBundleIdentifier: String,
                             browserSessionID: String, receivedAt: Date = Date()) throws -> Acceptance {
        let record = BrowserWindowVisibilityRecord(browserBundleIdentifier: browserBundleIdentifier,
            browserSessionID: browserSessionID, receivedAt: receivedAt, plan: plan)
        guard record.isValid else { return .rejected }
        return try persist(record, revealOnly: true)
    }

    /// An extension update can lose session storage while its browser process
    /// remains alive. Recover only already captured parking ownership; this is
    /// not a desired plan and cannot advance its revision or register anything.
    /// The host separately verifies that this process is still the live browser
    /// and that this exact intention is not currently enforcing restrictions.
    @discardableResult
    public func requestRegisteredRecovery(browserBundleIdentifier: String, browserSessionID: String,
                                          intentionSessionID: String, browserProcessIdentity: BrowserProcessIdentity,
                                          windowIDs: [Int], receivedAt: Date = Date()) throws -> Acceptance {
        guard validVisibilityBundle(browserBundleIdentifier), validVisibilityIdentity(browserSessionID),
              validVisibilityIdentity(intentionSessionID), browserProcessIdentity.isValid,
              receivedAt.timeIntervalSinceReferenceDate.isFinite,
              browserProcessIdentity.launched <= receivedAt.timeIntervalSinceReferenceDate,
              !windowIDs.isEmpty, windowIDs.count <= 256, Set(windowIDs).count == windowIDs.count,
              windowIDs.allSatisfy({ $0 >= 0 && $0 <= 9_007_199_254_740_991 }) else { return .rejected }
        let file = fileURL(browserBundleIdentifier: browserBundleIdentifier, browserSessionID: browserSessionID,
            intentionSessionID: intentionSessionID)
        return try withFileLock(file) {
            guard var record = read(file), record.browserBundleIdentifier == browserBundleIdentifier,
                  record.browserSessionID == browserSessionID, record.plan.intentionSessionID == intentionSessionID,
                  record.browserProcessIdentity == browserProcessIdentity,
                  Set(windowIDs).isSubset(of: Set(record.registeredParkingWindows.map(\.windowID))),
                  Set(windowIDs).isSubset(of: capturedWindowIDs(for: record)) else { return .rejected }
            let requested = Set(windowIDs)
            if requested.isSubset(of: Set(record.requestedRevealWindowIDs)) { return .unchanged }
            record.requestedRevealWindowIDs = Set(record.requestedRevealWindowIDs).union(requested).sorted()
            record.receivedAt = max(record.receivedAt, receivedAt)
            guard record.isValid else { return .rejected }
            let encoded = try JSONEncoder().encode(record)
            guard encoded.count <= Self.maximumFileBytes else { return .rejected }
            try encoded.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return .written
        }
    }

    private func persist(_ record: BrowserWindowVisibilityRecord, revealOnly: Bool) throws -> Acceptance {
        var record = record
        let browserBundleIdentifier = record.browserBundleIdentifier
        let browserSessionID = record.browserSessionID
        let plan = record.plan
        let file = fileURL(browserBundleIdentifier: browserBundleIdentifier, browserSessionID: browserSessionID,
            intentionSessionID: plan.intentionSessionID)
        return try withFileLock(file) {
            let previous = read(file)
            if FileManager.default.fileExists(atPath: file.path), previous == nil { return .rejected }
            if let previous {
                guard previous.browserBundleIdentifier == browserBundleIdentifier,
                      previous.browserSessionID == browserSessionID else { return .rejected }
                // A process proof belongs to the first accepted occurrence. A
                // restarted host may omit it, but cannot change or retrofit it.
                if let incoming = record.browserProcessIdentity,
                   incoming != previous.browserProcessIdentity { return .rejected }
                record.browserProcessIdentity = previous.browserProcessIdentity
                if revealOnly {
                    guard previous.plan.intentionSessionID == plan.intentionSessionID,
                          previous.plan.windows == plan.windows, previous.plan.parkingWindows == plan.parkingWindows,
                          Set(plan.revealWindowIDs).isSubset(of: Set(previous.plan.parkingWindows.map(\.windowID))) else { return .rejected }
                }
                if previous.plan.intentionSessionID == plan.intentionSessionID {
                    guard plan.revision >= previous.plan.revision else { return .rejected }
                    if plan.revision == previous.plan.revision {
                        return plan == previous.plan ? .unchanged : .rejected
                    }
                }
                record.registeredParkingWindows = previous.registeredParkingWindows + plan.parkingWindows.filter { current in
                    !previous.registeredParkingWindows.contains { $0.windowID == current.windowID }
                }
                record.requestedRevealWindowIDs = Set(previous.requestedRevealWindowIDs).union(plan.revealWindowIDs).sorted()
            } else if revealOnly {
                return .rejected
            }
            guard record.isValid else { return .rejected }
            let encoded = try JSONEncoder().encode(record)
            guard encoded.count <= Self.maximumFileBytes else { return .rejected }
            try encoded.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return .written
        }
    }

    /// Includes older intentions for recovery; consumers must separately fence
    /// active work by intention/profile lifetime and retain native ownership.
    public func records(browserBundleIdentifier: String) -> [BrowserWindowVisibilityRecord] {
        guard validVisibilityBundle(browserBundleIdentifier) else { return [] }
        let prefix = baseFileURL(browserBundleIdentifier: browserBundleIdentifier).deletingPathExtension().lastPathComponent + ".profile-"
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }.compactMap { file in
            guard let record = read(file), record.browserBundleIdentifier == browserBundleIdentifier,
                  file.standardizedFileURL == fileURL(browserBundleIdentifier: browserBundleIdentifier,
                      browserSessionID: record.browserSessionID, intentionSessionID: record.plan.intentionSessionID).standardizedFileURL else { return nil }
            return record
        }.sorted {
            ($0.browserSessionID, $0.plan.intentionSessionID) < ($1.browserSessionID, $1.plan.intentionSessionID)
        }
    }

    /// Native recovery already owns these exact identities; it need not discover
    /// or decode unrelated historical occurrences to read their reveal request.
    public func record(browserBundleIdentifier: String, browserSessionID: String,
                       intentionSessionID: String) -> BrowserWindowVisibilityRecord? {
        guard validVisibilityBundle(browserBundleIdentifier), validVisibilityIdentity(browserSessionID),
              validVisibilityIdentity(intentionSessionID) else { return nil }
        let file = fileURL(browserBundleIdentifier: browserBundleIdentifier, browserSessionID: browserSessionID,
            intentionSessionID: intentionSessionID)
        guard let record = read(file), record.browserBundleIdentifier == browserBundleIdentifier,
              record.browserSessionID == browserSessionID, record.plan.intentionSessionID == intentionSessionID else { return nil }
        return record
    }

    private func baseFileURL(browserBundleIdentifier: String) -> URL {
        let safe = browserBundleIdentifier.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return directory.appendingPathComponent("browser-window-visibility-\(safe).json")
    }

    private func read(_ file: URL) -> BrowserWindowVisibilityRecord? {
        guard let data = limitedData(file),
              let record = try? JSONDecoder().decode(BrowserWindowVisibilityRecord.self, from: data), record.isValid else { return nil }
        return record
    }

    private func limitedData(_ file: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: file), data.count <= Self.maximumFileBytes else { return nil }
        return data
    }

    private func withFileLock<T>(_ file: URL, _ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
}

/// Authorizes only a bounded browser-side restart recovery path. It does not
/// approve an AX operation, a new visibility claim, or reuse of native IDs.
public enum BrowserWindowVisibilityRestartPolicy {
    public enum PreviousProcessState: Equatable {
        /// The exact old PID no longer exists (e.g. kill(pid, 0) == ESRCH).
        case terminated
        /// The old PID exists, but verified live launch evidence is different.
        case reused(BrowserProcessIdentity)
        case running
        /// Includes absent AppKit data, EPERM and other inconclusive errors.
        case unknown
    }

    public static func permits(requestedPreviousIdentity: BrowserProcessIdentity?,
                               storedPreviousIdentity: BrowserProcessIdentity?,
                               currentIdentity: BrowserProcessIdentity?,
                               previousProcessState: PreviousProcessState,
                               hasFreshActiveIntention: Bool,
                               requestedPreviousBrowserSessionID: String,
                               storedPreviousBrowserSessionID: String,
                               currentBrowserSessionID: String) -> Bool {
        guard !hasFreshActiveIntention,
              validVisibilityIdentity(requestedPreviousBrowserSessionID),
              validVisibilityIdentity(storedPreviousBrowserSessionID),
              validVisibilityIdentity(currentBrowserSessionID),
              requestedPreviousBrowserSessionID == storedPreviousBrowserSessionID,
              currentBrowserSessionID != storedPreviousBrowserSessionID,
              let previous = storedPreviousIdentity, previous.isValid,
              requestedPreviousIdentity == previous,
              let current = currentIdentity, current.isValid, current != previous else { return false }
        switch previousProcessState {
        case .terminated:
            // A currently verified process cannot simultaneously have ESRCH.
            return current.pid != previous.pid
        case .reused(let live):
            guard live.isValid, live.pid == previous.pid, live.launched != previous.launched else { return false }
            // If the browser itself now has the recycled PID, both independent
            // pieces of current-process evidence must identify the same lifetime.
            return current.pid != previous.pid || current == live
        case .running, .unknown:
            return false
        }
    }
}

/// Recovery never treats missing AppKit metadata as proof that its owner died.
public enum BrowserWindowVisibilityRestorationPolicy {
    public enum ProcessState: Equatable {
        /// A native process probe positively reported ESRCH for the expected PID.
        case missing
        /// A successful liveness probe; AppKit identity can still be unavailable.
        case running(identity: BrowserProcessIdentity?, bundleIdentifier: String?)
        /// Permission failure or another inconclusive process probe.
        case unknown
    }
    public enum Disposition: Equatable { case restore, retain, discard }

    public static func disposition(expectedIdentity: BrowserProcessIdentity, expectedBundleIdentifier: String,
                                   processState: ProcessState) -> Disposition {
        guard expectedIdentity.isValid, validVisibilityBundle(expectedBundleIdentifier) else { return .retain }
        switch processState {
        case .missing:
            return .discard
        case .unknown:
            return .retain
        case .running(let observed, let bundle):
            guard let observed, observed.isValid, observed.pid == expectedIdentity.pid else { return .retain }
            if observed.launched != expectedIdentity.launched { return .discard }
            return bundle == expectedBundleIdentifier ? .restore : .retain
        }
    }
}

public enum BrowserWindowVisibilityMatching {
    /// Neutral input: callers may supply offscreen windows. No AppKit query or
    /// foreground/focus heuristic is performed by the identity matcher.
    public struct NativeCandidate: Equatable {
        public var id: UInt32
        public var pid: Int32
        public var bundle: String
        public var title: String
        public var frame: CGRect

        public init(id: UInt32, pid: Int32, bundle: String, title: String, frame: CGRect) {
            self.id = id; self.pid = pid; self.bundle = bundle; self.title = title; self.frame = frame
        }
    }

    public struct Match: Equatable {
        public var record: BrowserWindowVisibilityRecord
        public var window: BrowserWindowVisibilityWindow
        public var candidate: NativeCandidate
        public var isParking: Bool
    }

    private struct NativeIdentity: Hashable {
        var id: UInt32
        var pid: Int32
    }

    public static func match(window: BrowserWindowVisibilityWindow, browserBundleIdentifier: String,
                             candidates: [NativeCandidate]) -> NativeCandidate? {
        guard window.isValid, validVisibilityBundle(browserBundleIdentifier) else { return nil }
        let matches = candidates.filter { candidate in
            guard candidate.id > 0, candidate.pid > 0, candidate.bundle == browserBundleIdentifier,
                  BrowserWindowVisibilityWindow.validFrame(candidate.frame),
                  BrowserWindowMatching.sameWindowTitle(candidate.title, window.title) else { return false }
            let frame = window.frame.rect
            return abs(candidate.frame.origin.x - frame.origin.x) <= 3
                && abs(candidate.frame.origin.y - frame.origin.y) <= 3
                && abs(candidate.frame.size.width - frame.size.width) <= 3
                && abs(candidate.frame.size.height - frame.size.height) <= 3
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Reverse uniqueness is required across all supplied profiles, not just
    /// within one plan. Two browser claims cannot own the same native window.
    public static func matches(records: [BrowserWindowVisibilityRecord], candidates: [NativeCandidate]) -> [Match] {
        let proposed = records.filter(\.isValid).flatMap { record in
            (record.plan.windows + record.plan.parkingWindows).compactMap { window -> Match? in
                guard let candidate = match(window: window, browserBundleIdentifier: record.browserBundleIdentifier,
                                            candidates: candidates) else { return nil }
                return Match(record: record, window: window, candidate: candidate,
                    isParking: record.plan.parkingWindows.contains { $0.windowID == window.windowID })
            }
        }
        let claimCounts = Dictionary(grouping: proposed, by: { NativeIdentity(id: $0.candidate.id, pid: $0.candidate.pid) }).mapValues(\.count)
        return proposed.filter { claimCounts[NativeIdentity(id: $0.candidate.id, pid: $0.candidate.pid)] == 1 }
    }
}

private func validVisibilityIdentity(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256
}

private func validVisibilityBundle(_ value: String) -> Bool {
    validVisibilityIdentity(value) && value.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 || $0 == 95
    }
}
