import Darwin
import Foundation

/// One engine owns global input, window effects and the Browser Guard transport.
/// The apps have separate workspaces; only this small coordination record is shared.
public struct IntentEngineOwner: Codable, Equatable, Sendable {
    public var pid: Int32
    public var channel: IntentBuildChannel
    public var generation: UUID
    public var activeSession: Bool
    public var appName: String { channel.appName }
    public var bundleIdentifier: String { channel.bundleIdentifier }

    public init(pid: Int32, channel: IntentBuildChannel, generation: UUID = UUID(), activeSession: Bool = false) {
        self.pid = pid; self.channel = channel; self.generation = generation; self.activeSession = activeSession
    }

    public func sameEngine(as other: Self) -> Bool {
        pid == other.pid && channel == other.channel && generation == other.generation
    }
}

public enum IntentEngineLeaseError: LocalizedError {
    case busy(IntentEngineOwner?)
    case lostOwnership
    case invalidDirectory
    case system(Int32)

    public var errorDescription: String? {
        switch self {
        case .busy(let owner):
            return "\(owner?.appName ?? "Another Intent app") is already running. Finish its intention before switching apps."
        case .lostOwnership: return "Intent's engine ownership changed. Reopen the app to reconnect safely."
        case .invalidDirectory: return "Intent's private engine directory is not safe to use."
        case .system(let status): return "Intent could not reserve its engine (\(status))."
        }
    }
}

public final class IntentEngineLease {
    public static let switchNotificationName = "dev.loganmondi.intent.engine.switch-request"
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".intent-engine", isDirectory: true)
    }

    public let directory: URL
    private let mutex = NSLock()
    private var descriptor: Int32 = -1
    private var owned: IntentEngineOwner?

    public init(directory: URL = IntentEngineLease.defaultDirectory) {
        self.directory = directory.standardizedFileURL
    }

    public var owner: IntentEngineOwner? { mutex.withLock { owned } }
    public var isOwner: Bool {
        mutex.withLock {
            guard descriptor >= 0, let owned, let record = Self.readRecord(directory: directory) else { return false }
            return record.sameEngine(as: owned)
        }
    }

    @discardableResult
    public func acquire(channel: IntentBuildChannel = .current, pid: Int32 = getpid()) throws -> IntentEngineOwner {
        try mutex.withLock {
            if let owned, descriptor >= 0 { return owned }
            try Self.prepareDirectory(directory)
            let fd = Darwin.open(Self.lockURL(directory).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw IntentEngineLeaseError.system(errno) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let status = errno
                Darwin.close(fd)
                if status == EWOULDBLOCK || status == EAGAIN {
                    throw IntentEngineLeaseError.busy(Self.currentOwner(directory: directory))
                }
                throw IntentEngineLeaseError.system(status)
            }
            let record = IntentEngineOwner(pid: pid, channel: channel)
            do { try Self.write(record, directory: directory) } catch {
                flock(fd, LOCK_UN); Darwin.close(fd); throw error
            }
            descriptor = fd; owned = record
            return record
        }
    }

    public func updateActiveSession(_ active: Bool) throws {
        try mutex.withLock {
            guard descriptor >= 0, var record = owned,
                  Self.readRecord(directory: directory)?.sameEngine(as: record) == true else {
                throw IntentEngineLeaseError.lostOwnership
            }
            guard record.activeSession != active else { return }
            record.activeSession = active
            try Self.write(record, directory: directory)
            owned = record
        }
    }

    public func release() {
        mutex.withLock {
            guard descriptor >= 0 else { return }
            if let owned, Self.readRecord(directory: directory)?.sameEngine(as: owned) == true {
                try? FileManager.default.removeItem(at: Self.ownerURL(directory))
            }
            flock(descriptor, LOCK_UN); Darwin.close(descriptor)
            descriptor = -1; owned = nil
        }
    }

    deinit { release() }

    /// Both a live process and the held advisory lock are required. A stale JSON
    /// file after a crash is never sufficient to route a browser connection.
    public static func currentOwner(directory: URL = defaultDirectory) -> IntentEngineOwner? {
        guard let record = readRecord(directory: directory), record.pid > 0,
              Darwin.kill(record.pid, 0) == 0 || errno == EPERM else { return nil }
        let fd = Darwin.open(lockURL(directory).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        guard errno == EWOULDBLOCK || errno == EAGAIN else { return nil }
        // An ownership handoff may occur between reading metadata and probing
        // the lock. Never return the previous generation under a new owner.
        guard let verified = readRecord(directory: directory), verified.sameEngine(as: record) else { return nil }
        return verified
    }

    public static func nativeHostOwner(channel: IntentBuildChannel = .current,
                                       directory: URL = defaultDirectory) -> IntentEngineOwner? {
        guard let owner = currentOwner(directory: directory), owner.channel == channel else { return nil }
        return owner
    }

    public static func ownerStillMatches(_ captured: IntentEngineOwner,
                                        directory: URL = defaultDirectory) -> Bool {
        currentOwner(directory: directory)?.sameEngine(as: captured) == true
    }

    private static func lockURL(_ directory: URL) -> URL { directory.appendingPathComponent("engine.lock") }
    private static func ownerURL(_ directory: URL) -> URL { directory.appendingPathComponent("owner.json") }

    private static func prepareDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw IntentEngineLeaseError.invalidDirectory }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw IntentEngineLeaseError.invalidDirectory
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func readRecord(directory: URL) -> IntentEngineOwner? {
        let url = ownerURL(directory)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 16_384,
              let data = try? Data(contentsOf: url),
              let owner = try? JSONDecoder().decode(IntentEngineOwner.self, from: data) else { return nil }
        return owner
    }

    private static func write(_ record: IntentEngineOwner, directory: URL) throws {
        let url = ownerURL(directory)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
