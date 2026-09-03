import Foundation

public enum IntentLocalDataSecurity {
    public static func hardenDefaultDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        try harden(directory: homeDirectory.appendingPathComponent(".intent", isDirectory: true))
    }

    public static func harden(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }
}
