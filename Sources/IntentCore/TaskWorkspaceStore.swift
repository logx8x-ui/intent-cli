import Foundation
import Darwin

/// Local Test Intent data only. Reads never rewrite the user's file; corrupt
/// files are kept beside a repaired save, and future formats are read-only.
/// Use on one serial owner (the task workspace's main-actor view model).
public final class TaskWorkspaceStore {
    public let fileURL: URL
    public private(set) var didRecoverFromBackup = false
    private let usesDefaultLocation: Bool
    private var hasLoaded = false
    private var loadedBytes: Data?

    public var recoveryFileURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("last-good.json")
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? IntentEnvironment.dataDirectory.appendingPathComponent("task-workspace.json")
        usesDefaultLocation = fileURL == nil
    }

    public func load() throws -> TaskWorkspaceDocument {
        try checkAccess()
        hasLoaded = false
        didRecoverFromBackup = false
        loadedBytes = try readIfPresent(fileURL)
        guard let loadedBytes else {
            if let backup = try readIfPresent(recoveryFileURL) {
                let recovered = try decode(backup)
                didRecoverFromBackup = true
                hasLoaded = true
                return recovered
            }
            hasLoaded = true
            return .empty()
        }
        do {
            let document = try decode(loadedBytes)
            hasLoaded = true
            return document
        } catch let error as TaskWorkspaceError where error.isFutureFormat {
            // A rollback must not silently replace newer data with an old backup.
            throw error
        } catch let primaryError {
            guard let backup = try readIfPresent(recoveryFileURL), let recovered = try? decode(backup) else {
                throw primaryError
            }
            didRecoverFromBackup = true
            hasLoaded = true
            return recovered
        }
    }

    public func save(_ document: TaskWorkspaceDocument) throws {
        try checkAccess()
        try document.validate()
        if !hasLoaded { _ = try load() }
        guard try readIfPresent(fileURL) == loadedBytes else { throw TaskWorkspaceError.changedOnDisk }
        let directory = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if didRecoverFromBackup, let loadedBytes {
            let preserved = directory.appendingPathComponent("task-workspace-recovered-\(UUID().uuidString).json")
            try writePrivate(loadedBytes, to: preserved)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try writePrivate(data, to: fileURL)
        self.loadedBytes = data
        didRecoverFromBackup = false
        // Primary has already committed; a failed backup cannot make the UI
        // roll back to a stale document that would disagree with the saved one.
        try? writePrivate(data, to: recoveryFileURL)
    }

    private func checkAccess() throws {
        guard !usesDefaultLocation || IntentBuildChannel.current == .development || IntentEnvironment.isQA else {
            throw TaskWorkspaceError.developmentOnly
        }
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        // Refuse symlinked files, including a symlinked recovery file.
        for url in [fileURL, recoveryFileURL] {
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]) {
                guard values.isSymbolicLink != true, values.isRegularFile == true else {
                    throw TaskWorkspaceError.unsafeFile
                }
            }
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw TaskWorkspaceError.unsafeFile
            }
        }
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".task-workspace-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw TaskWorkspaceError.unsafeFile
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // Commit only once the private, complete file is on disk. There are no
        // throwing operations after rename that could falsely report failure.
        let result = temporary.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func decode(_ data: Data) throws -> TaskWorkspaceDocument {
        // Decodable normally discards unknown keys. Reject them instead, so
        // editing with an older binary never strips information it cannot show.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TaskWorkspaceError.invalidDocument
        }
        if let version = object["schemaVersion"] as? Int,
           version != TaskWorkspaceDocument.currentSchemaVersion {
            throw TaskWorkspaceError.unsupportedVersion(version)
        }
        try requireKeys(object, allowed: ["schemaVersion", "folders"])
        for folder in object["folders"] as? [[String: Any]] ?? [] {
            try requireKeys(folder, allowed: ["id", "title", "position", "tasks"])
            if let position = folder["position"] as? [String: Any] {
                try requireKeys(position, allowed: ["x", "y"])
            }
            for task in folder["tasks"] as? [[String: Any]] ?? [] {
                try requireKeys(task, allowed: ["id", "title", "isCompleted", "linkedIntentionID"])
            }
        }
        let document = try JSONDecoder().decode(TaskWorkspaceDocument.self, from: data)
        try document.validate()
        return document
    }

    private func requireKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw TaskWorkspaceError.unknownFields }
    }
}

private extension TaskWorkspaceError {
    var isFutureFormat: Bool {
        switch self {
        case .unsupportedVersion, .unknownFields: return true
        default: return false
        }
    }
}
