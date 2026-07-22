import AppKit
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
            ?? assets.first { $0.name.lowercased().hasSuffix(".dmg") }
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
                guard release.diskImage != nil else {
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
              !isInstalling else { return }

        isInstalling = true
        errorMessage = nil

        Task {
            do {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("IntentUpdate-(UUID().uuidString)", isDirectory: true)
                let diskImage = root.appendingPathComponent("Intent.dmg")
                let mountPoint = root.appendingPathComponent("mounted", isDirectory: true)
                try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

                var request = URLRequest(url: asset.browserDownloadURL)
                request.setValue("Intent/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 120
                let (downloadedFile, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw IntentUpdateError.downloadFailed
                }
                try FileManager.default.moveItem(at: downloadedFile, to: diskImage)

                try mount(diskImage, at: mountPoint)
                guard let package = try FileManager.default.contentsOfDirectory(
                    at: mountPoint,
                    includingPropertiesForKeys: nil
                ).first(where: { $0.pathExtension.lowercased() == "pkg" }) else {
                    throw IntentUpdateError.missingInstaller
                }

                try launchInstaller(package: package, mountPoint: mountPoint)
            } catch {
                errorMessage = error.localizedDescription
                isInstalling = false
            }
        }
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
        case .mountFailed(let detail):
            detail.isEmpty ? "The Intent update could not be opened." : detail
        case .missingInstaller:
            "The Intent update does not contain its installer."
        }
    }
}
