import AppKit
import IntentCore

/// Per-user registration takes precedence over stale system-wide installer manifests.
@MainActor
enum IntentBrowserSetup {
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
    static func open(_ browserID: String) {
        guard !IntentEnvironment.isQA else { return }
        do { try register() } catch {
            let alert = NSAlert(); alert.messageText = "Couldn’t connect Browser Guard"; alert.informativeText = error.localizedDescription; alert.runModal(); return
        }
        guard let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserID) else { return }
        let chrome = browserID == "com.google.Chrome"
        let folder = root.appendingPathComponent(chrome ? "Chrome" : "Firefox")
        let alert = NSAlert()
        alert.messageText = chrome ? "Connect Chrome · three quick steps" : "Connect Firefox for this test"
        alert.informativeText = chrome
            ? "1. Turn on Developer mode in the top-right.\n2. Click Load unpacked. In the folder chooser press ⌘⇧G, paste the folder path, and press Return.\n3. Select the Chrome folder. If Intent Browser Guard is already listed, remove the old copy first.\n\nThe folder path has been copied. Return to Intent; the check turns green only when tabs work."
            : "1. Click Load Temporary Add-on.\n2. In the chooser press ⌘⇧G and paste the copied folder path.\n3. Choose manifest.json.\n\nThis tester extension must be loaded again after Firefox restarts. Intent will confirm when tabs work."
        alert.addButton(withTitle: "Open setup")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(folder.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        NSWorkspace.shared.open([URL(string: chrome ? "chrome://extensions" : "about:debugging#/runtime/this-firefox")!], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
    }
}
