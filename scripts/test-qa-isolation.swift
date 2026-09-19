import Foundation

@main
struct IntentQASpec {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("intent-qa-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let marker = directory.appendingPathComponent(IntentEnvironment.qaMarker)
        func validate(_ path: String, bundle: String? = IntentEnvironment.qaBundleIdentifier) throws -> URL {
            try IntentEnvironment.validatedQADirectory(path: path, bundleIdentifier: bundle, executableName: "IntentQAApp")
        }
        func rejects(_ action: () throws -> URL, _ message: String) {
            do { _ = try action(); preconditionFailure(message) } catch {}
        }
        rejects({ try validate(directory.path) }, "A directory without the QA marker must be rejected")
        try Data(IntentEnvironment.qaMarkerContents.utf8).write(to: marker)
        let validated = try validate(directory.path)
        precondition(validated == directory.standardizedFileURL.resolvingSymlinksInPath())
        rejects({ try validate(directory.path, bundle: "dev.loganmondi.intent") }, "The daily app cannot use QA mode")
        rejects({ try validate(fm.homeDirectoryForCurrentUser.appendingPathComponent(".intent").path) }, "The daily data directory must be rejected")
        rejects({ try validate("relative/intent-qa-test") }, "Relative paths must be rejected")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        rejects({ try validate(directory.path) }, "A nonprivate directory must be rejected")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let nested = directory.appendingPathComponent("intent-qa-nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(IntentEnvironment.qaMarkerContents.utf8).write(to: nested.appendingPathComponent(IntentEnvironment.qaMarker))
        rejects({ try validate(nested.path) }, "Only dedicated direct children of the temporary directory are permitted")
        print("Intent QA root validation spec passed")
    }
}
