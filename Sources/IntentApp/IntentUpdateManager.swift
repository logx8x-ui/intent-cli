import AppKit
import CryptoKit
import Foundation
import IntentCore

struct IntentGitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    var version: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    var diskImage: Asset? {
        assets.first { $0.name == "Intent.dmg" }
    }

    var releaseManifest: Asset? {
        assets.first { $0.name == "release-manifest.json" }
    }
}

private struct IntentReleaseManifest: Decodable {
    let version: String
    let sha256: String
    let teamID: String
    let notarized: Bool

    enum CodingKeys: String, CodingKey {
        case version
        case sha256
        case teamID = "team_id"
        case notarized
    }
}

@MainActor
final class IntentUpdateManager: ObservableObject {
    static let shared = IntentUpdateManager()

    @Published private(set) var availableRelease: IntentGitHubRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published var errorMessage: String?

    private let latestReleaseURL = URL(
        string: "https://api.github.com/repos/logx8x-ui/intent-cli/releases/latest"
    )!

    private init() {}

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func checkForUpdates(force: Bool = false) {
        guard !isChecking, !isInstalling else { return }
        if availableRelease != nil, !force { return }

        isChecking = true
        errorMessage = nil

        Task {
            defer { isChecking = false }
            do {
                var request = URLRequest(url: latestReleaseURL)
                request.setValue("Intent/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 15

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw IntentUpdateError.releaseLookupFailed
                }

                let release = try JSONDecoder().decode(IntentGitHubRelease.self, from: data)
                guard release.diskImage != nil, release.releaseManifest != nil else {
                    throw IntentUpdateError.missingDiskImage
                }
                availableRelease = AppReleaseVersion.isNewer(release.version, than: currentVersion)
                    ? release
                    : nil
            } catch {
                if force {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func installAvailableUpdate() {
        guard let release = availableRelease,
              let asset = release.diskImage,
              let manifestAsset = release.releaseManifest,
              !isInstalling else { return }

        isInstalling = true
        errorMessage = nil

        Task {
            do {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("IntentUpdate-(UUID().uuidString)", isDirectory: true)
                let diskImage = root.appendingPathComponent("Intent.dmg")
                let manifestFile = root.appendingPathComponent("release-manifest.json")
                let mountPoint = root.appendingPathComponent("mounted", isDirectory: true)
                try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

                try await download(asset.browserDownloadURL, to: diskImage)
                try await download(manifestAsset.browserDownloadURL, to: manifestFile)
                let manifest = try JSONDecoder().decode(
                    IntentReleaseManifest.self,
                    from: Data(contentsOf: manifestFile)
                )
                guard manifest.notarized,
                      !manifest.teamID.isEmpty,
                      manifest.version == release.version,
                      try sha256(of: diskImage) == manifest.sha256.lowercased() else {
                    throw IntentUpdateError.unverifiedRelease
                }

                try mount(diskImage, at: mountPoint)
                guard let package = try FileManager.default.contentsOfDirectory(
                    at: mountPoint,
                    includingPropertiesForKeys: nil
                ).first(where: { $0.pathExtension.lowercased() == "pkg" }) else {
                    throw IntentUpdateError.missingInstaller
                }
                try verify(package: package, teamID: manifest.teamID)

                try launchInstaller(package: package, mountPoint: mountPoint)
            } catch {
                errorMessage = error.localizedDescription
                isInstalling = false
            }
        }
    }

    private func download(_ source: URL, to destination: URL) async throws {
        var request = URLRequest(url: source)
        request.setValue("Intent/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (downloadedFile, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw IntentUpdateError.downloadFailed
        }
        try FileManager.default.moveItem(at: downloadedFile, to: destination)
    }

    private func sha256(of file: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: file))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func verify(package: URL, teamID: String) throws {
        let signatureOutput = try processOutput(
            executable: "/usr/sbin/pkgutil",
            arguments: ["--check-signature", package.path]
        )
        guard signatureOutput.contains("(\(teamID))")
                || signatureOutput.contains("Team Identifier: \(teamID)") else {
            throw IntentUpdateError.unverifiedRelease
        }
        _ = try processOutput(
            executable: "/usr/sbin/spctl",
            arguments: ["--assess", "--type", "install", "--verbose=2", package.path]
        )
    }

    private func processOutput(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw IntentUpdateError.unverifiedRelease
        }
        return text
    }

    private func mount(_ diskImage: URL, at mountPoint: URL) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach", diskImage.path,
            "-nobrowse", "-readonly", "-mountpoint", mountPoint.path
        ]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw IntentUpdateError.mountFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func launchInstaller(package: URL, mountPoint: URL) throws {
        let command = [
            "/usr/sbin/installer -pkg (shellQuote(package.path)) -target /",
            "status=$?",
            "/usr/bin/hdiutil detach (shellQuote(mountPoint.path)) -force >/dev/null 2>&1 || true",
            "exit $status"
        ].joined(separator: "; ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            command
        ]
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            Task { @MainActor in
                IntentUpdateManager.shared.isInstalling = false
                IntentUpdateManager.shared.errorMessage = "The Intent update was cancelled or could not be installed."
            }
        }
        try process.run()
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum IntentUpdateError: LocalizedError {
    case releaseLookupFailed
    case missingDiskImage
    case downloadFailed
    case unverifiedRelease
    case mountFailed(String)
    case missingInstaller

    var errorDescription: String? {
        switch self {
        case .releaseLookupFailed:
            "Intent could not check GitHub for an update."
        case .missingDiskImage:
            "The latest Intent release does not contain Intent.dmg."
        case .downloadFailed:
            "The Intent update could not be downloaded."
        case .unverifiedRelease:
            "Intent refused this update because its Apple signature or published checksum could not be verified."
        case .mountFailed(let detail):
            detail.isEmpty ? "The Intent update could not be opened." : detail
        case .missingInstaller:
            "The Intent update does not contain its installer."
        }
    }
}
