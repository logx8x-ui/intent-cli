import AppKit
import Darwin
import IntentCore
import SwiftUI

/// Per-user registration takes precedence over stale system-wide installer manifests.
@MainActor
enum IntentBrowserSetup {
    private static var setupWindow: NSWindow?
    private static let setupWindowDelegate = SetupWindowDelegate()
    private static var handoffActive = false

    private final class SetupWindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard handoffActive else { return }
            handoffActive = false
            IntentRuntime.shared.endBrowserSetupHandoff()
        }
    }

    /// Reopening Intent should return to its setup window without covering it
    /// with the suspended overview or onboarding coach.
    static func focusIfPresented() -> Bool {
        guard let window = setupWindow, window.isVisible else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    static var root: URL { IntentEnvironment.dataDirectory.appendingPathComponent("browser-guard") }
    static func register() throws {
        guard !IntentEnvironment.isQA else { return }
        let fm = FileManager.default
        let host = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/IntentNativeHost")
        guard fm.isExecutableFile(atPath: host.path) else { return }
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BrowserGuard")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for browser in ["Chrome", "Firefox"] {
            let source = resources.appendingPathComponent(browser)
            let target = root.appendingPathComponent(browser)
            // Update files in place: Chrome's unpacked extension keeps this stable path.
            if fm.fileExists(atPath: source.path), let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let file as URL in files {
                    let relative = String(file.path.dropFirst(source.path.count + 1))
                    let destination = target.appendingPathComponent(relative)
                    if (try file.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    } else {
                        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data(contentsOf: file).write(to: destination, options: .atomic)
                    }
                }
            }
        }
        var changed = false
        for (directory, access) in [
            ("Google/Chrome/NativeMessagingHosts", ["allowed_origins": ["chrome-extension://aibdbhjdckeeejpggfpfaghmomopjbpb/", "chrome-extension://ffgfjfpkddgimambgmahlodjjojmjnbc/"]]),
            ("Mozilla/NativeMessagingHosts", ["allowed_extensions": ["intent-firefox@loganmondi.dev"]])
        ] {
            let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/" + directory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var manifest: [String: Any] = ["name": "intent_native_host", "description": "Intent Browser Guard", "path": host.path, "type": "stdio"]
            access.forEach { manifest[$0.key] = $0.value }
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            let destination = folder.appendingPathComponent("intent_native_host.json")
            if (try? Data(contentsOf: destination)) != data { changed = true; try data.write(to: destination, options: .atomic) }
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if changed || UserDefaults.standard.string(forKey: "intentBrowserHostBuild") != version {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-u", String(getuid()), "-x", "IntentNativeHost"]
            process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit() } catch { NSLog("Browser reconnect will occur when the browser restarts") }
            UserDefaults.standard.set(version, forKey: "intentBrowserHostBuild")
        }
    }
    static func open(_ browserID: String? = nil) {
        guard !IntentEnvironment.isQA else { return }
        do { try register() } catch {
            let alert = NSAlert(); alert.messageText = "Couldn’t connect Browser Guard"; alert.informativeText = error.localizedDescription; alert.runModal(); return
        }
        let configuration = releaseConfiguration()
        let discovery = IntentBrowserProfileDiscovery(
            applicationSupport: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"),
            requiredVersion: configuration.requiredVersion, development: configuration.development)
        let view = IntentBrowserSetupView(profiles: { discovery.discover() }, preferredBrowser: browserID.flatMap(IntentSetupBrowser.init(rawValue:)),
            configuration: configuration, openProfile: { profile, destination in
                open(profile: profile, destination: destination, configuration: configuration)
            }, close: { setupWindow?.close() })
        let controller = NSHostingController(rootView: view)
        let window = setupWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Intent · Browser profiles"
        window.isReleasedWhenClosed = false
        window.delegate = setupWindowDelegate
        window.contentViewController = controller
        window.minSize = NSSize(width: 640, height: 620)
        if setupWindow == nil { window.center() }
        setupWindow = window
        if !handoffActive {
            handoffActive = true
            IntentRuntime.shared.beginBrowserSetupHandoff()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func releaseConfiguration() -> IntentBrowserSetupReleaseConfiguration {
        let manifest = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BrowserGuard/Chrome/manifest.json")
        let metadata = (try? Data(contentsOf: manifest)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let version = metadata?["version"] as? String ?? "unavailable"
        let package = signedFirefoxPackage(requiredVersion: version)
        return .init(requiredVersion: version, development: IntentBuildChannel.current == .development,
                     chromePublishedVersion: Bundle.main.object(forInfoDictionaryKey: "IntentChromePublishedGuardVersion") as? String,
                     firefoxSignedVersion: package == nil ? nil : version, firefoxPackage: package)
    }

    /// A normal launch setup only offers the exact signed package embedded in
    /// the verified release. An old signed file does not qualify as a match.
    private static func signedFirefoxPackage(requiredVersion: String) -> URL? {
        let package = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BrowserGuard/Intent-Firefox-Extension.xpi")
        guard FileManager.default.fileExists(atPath: package.path),
              let manifest = archiveOutput(package, arguments: ["-p", package.path, "manifest.json"]),
              let metadata = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              metadata["version"] as? String == requiredVersion,
              let listing = archiveOutput(package, arguments: ["-Z", "-1", package.path]),
              String(data: listing, encoding: .utf8)?.components(separatedBy: .newlines).contains("META-INF/mozilla.rsa") == true else { return nil }
        // Cryptographic signing and artifact hash verification remain owned by
        // build-release/verify-release; this prevents stale/missing setup files.
        return package
    }

    private static func archiveOutput(_ package: URL, arguments: [String]) -> Data? {
        guard let size = (try? package.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 32 * 1024 * 1024 else { return nil }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? output : nil
    }

    private static func open(profile: IntentLocalBrowserProfile, destination: String,
                             configuration: IntentBrowserSetupReleaseConfiguration) -> String? {
        guard let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.browser.rawValue) else {
            return "\(profile.browser.name) isn’t installed here. Install the browser, then refresh this list."
        }
        let lock = profile.browser == .firefox ? firefoxProfileLock(profile.directory) : nil
        let plan = IntentBrowserProfileLaunchPlan.plan(profile: profile, destination: destination, firefoxAlreadyOpen: lock != nil)
        let instructions: String
        if configuration.development && !profile.guardStatus.isMatching {
            let folder = root.appendingPathComponent(profile.browser == .chrome ? "Chrome" : "Firefox")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(folder.path, forType: .string)
            instructions = profile.browser == .chrome
                ? "In \(profile.name), turn on Developer mode, choose Load unpacked, then use the copied Chrome folder. Browser confirmation is required."
                : "In \(profile.name), open about:debugging#/runtime/this-firefox, choose Load Temporary Add-on, then choose manifest.json in the copied folder. This private development add-on must be loaded again after Firefox restarts."
        } else {
            instructions = "In \(profile.name), approve \(profile.browser.name)’s installation prompt, then return to Intent. Choose Refresh to check the installed version."
        }
        switch plan {
        case .chromeSetupInstructions:
            guard configuration.development else { return "Open the official Chrome Web Store page to manage Browser Guard." }
            let folder = root.appendingPathComponent("Chrome")
            let pages = root.appendingPathComponent("profile-setup", isDirectory: true)
            let file = pages.appendingPathComponent("chrome-" + BrowserProfileSnapshots.component(profile.id) + ".html")
            do {
                try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try Data(IntentBrowserProfileSetupPage.html(profile: profile, requiredVersion: configuration.requiredVersion,
                    folder: folder).utf8).write(to: file, options: .atomic)
            } catch {
                return "Chrome won’t open its extensions page from an external launch. In \(profile.name), press ⌘L, enter chrome://extensions, and press Return. " + instructions
            }
            // Use the same exact-profile route with a safe local URL, which
            // Chrome accepts. Never pass chrome://extensions to its launcher.
            _ = open(profile: profile, destination: file.absoluteString, configuration: configuration)
            return profile.guardStatus.isMatching
                ? "Opened a setup guide in \(profile.name). Browser Guard is already installed; return to Intent and verify this profile’s live connection."
                : "Opened setup instructions in \(profile.name). Follow the guide in Chrome; the extension folder path is copied."
        case .useOpenFirefoxProfile:
            if let pid = lock, pid > 0 { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps]) }
            if !configuration.development || profile.guardStatus.isMatching {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(destination, forType: .string)
            }
            let instruction = configuration.development && !profile.guardStatus.isMatching
                ? instructions
                : "The setup address has been copied. In the already-open \(profile.name) Firefox window, press ⌘L, paste it, and press Return. Approve Firefox’s prompt."
            return instruction + " Firefox cannot reliably route an external setup link to an already-open named profile; Intent leaves your other profiles and tabs untouched."
        case .open(let arguments):
            let options = NSWorkspace.OpenConfiguration()
            options.arguments = arguments
            options.activates = true
            // Launch Services only passes argv to a new app instance. Chrome
            // then forwards its profile-directory request through its own
            // singleton machinery; reusing the running app here loses argv.
            options.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: browser, configuration: options) { _, error in
                if let error {
                    DispatchQueue.main.async {
                        let alert = NSAlert(); alert.messageText = "Browser setup couldn’t open"
                        alert.informativeText = "Your profiles haven’t been changed. " + error.localizedDescription
                        alert.addButton(withTitle: "OK"); alert.runModal()
                    }
                }
            }
            if profile.guardStatus.isMatching { return "Opened \(profile.name). Keep Browser Guard on and return to Intent to verify its live connection." }
            return instructions
        }
    }

    /// Read the existing lock owner; never acquire, remove, or replace a lock.
    /// An unreadable lock is treated conservatively as an open profile.
    private static func firefoxProfileLock(_ directory: URL) -> pid_t? {
        for component in [".parentlock", "parent.lock"] {
            let path = directory.appendingPathComponent(component).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { return 0 }
            defer { Darwin.close(descriptor) }
            var query = flock()
            query.l_type = Int16(F_WRLCK); query.l_whence = Int16(SEEK_SET)
            guard fcntl(descriptor, F_GETLK, &query) != -1 else { return 0 }
            if query.l_type != Int16(F_UNLCK) { return query.l_pid }
        }
        return nil
    }
}
