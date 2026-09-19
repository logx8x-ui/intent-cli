import Foundation

/// Explicit opt-in isolation for a separate QA bundle. Invalid QA configuration
/// stops startup rather than silently falling back to the user's real workspace.
public enum IntentEnvironment {
    public static let qaBundleIdentifier = "dev.loganmondi.intent.qa"
    public static let qaMarker = ".intent-qa-root"
    public static let qaMarkerContents = "Intent isolated QA data v1\n"

    private static let qaDirectory: URL? = {
        let environment = ProcessInfo.processInfo.environment
        let identifier = Bundle.main.bundleIdentifier
        guard let path = environment["INTENT_QA_ROOT"] else {
            precondition(identifier != qaBundleIdentifier, "Intent QA requires INTENT_QA_ROOT; refusing the daily workspace.")
            return nil
        }
        do {
            return try validatedQADirectory(
                path: path,
                bundleIdentifier: identifier,
                executableName: URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
            )
        } catch {
            preconditionFailure("Unsafe Intent QA configuration: \(error.localizedDescription)")
        }
    }()

    public static var isQA: Bool { qaDirectory != nil }

    public static func validateLaunch() { _ = qaDirectory }

    public static var dataDirectory: URL {
        qaDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".intent", isDirectory: true)
    }

    /// Explicit fixture homes used by existing tests remain independent.
    public static func dataDirectory(forHome home: URL) -> URL {
        if home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
            return dataDirectory
        }
        return home.appendingPathComponent(".intent", isDirectory: true)
    }

    public static func validatedQADirectory(
        path: String,
        bundleIdentifier: String?,
        executableName: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        guard bundleIdentifier == qaBundleIdentifier || executableName == "IntentQASpec" else {
            throw QAConfigurationError.invalidExecutable
        }
        guard path.hasPrefix("/") else { throw QAConfigurationError.invalidDirectory }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let allowedParents = [temporaryDirectory, URL(fileURLWithPath: "/private/tmp", isDirectory: true)]
            .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard allowedParents.contains(directory.deletingLastPathComponent().path),
              directory.lastPathComponent.hasPrefix("intent-qa-"),
              directory.lastPathComponent.count > "intent-qa-".count else {
            throw QAConfigurationError.invalidDirectory
        }
        let marker = directory.appendingPathComponent(qaMarker)
        guard (try? String(contentsOf: marker, encoding: .utf8)) == qaMarkerContents else {
            throw QAConfigurationError.missingMarker
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw QAConfigurationError.invalidDirectory
        }
        return directory
    }

    public enum QAConfigurationError: LocalizedError {
        case invalidExecutable, invalidDirectory, missingMarker
        public var errorDescription: String? {
            switch self {
            case .invalidExecutable: return "Only the separate Intent QA app or IntentQASpec may use a QA workspace."
            case .invalidDirectory: return "Use a private intent-qa-* directory directly inside the system temporary directory."
            case .missingMarker: return "The QA workspace marker is missing; create the workspace with scripts/build-qa.sh."
            }
        }
    }
}
