import Foundation
import Darwin

enum IntentSetupBrowser: String, CaseIterable, Identifiable, Codable {
    case chrome = "com.google.Chrome"
    case firefox = "org.mozilla.firefox"
    var id: String { rawValue }
    var name: String { self == .chrome ? "Chrome" : "Firefox" }
}

enum IntentSetupBrowserChoice: String, Codable, CaseIterable {
    case firefox, chrome, both
    func includes(_ browser: IntentSetupBrowser) -> Bool {
        self == .both || (self == .firefox && browser == .firefox) || (self == .chrome && browser == .chrome)
    }

    /// Only a single, explicit installer argument can seed a fresh setup.
    /// Duplicate, incomplete and unknown values are ignored in their entirety.
    static func installerChoice(arguments: [String]) -> Self? {
        let values = arguments.filter { $0 == "--setup-browsers" || $0.hasPrefix("--setup-browsers=") }
        guard values.count == 1, let argument = values.first,
              argument.hasPrefix("--setup-browsers=") else { return nil }
        return Self(rawValue: String(argument.dropFirst("--setup-browsers=".count)))
    }

    static func installerReceipt(data: Data, appBuild: String) -> Self? {
        struct Receipt: Decodable { let version: Int; let browsers: IntentSetupBrowserChoice; let app_build: String }
        guard !appBuild.isEmpty, data.count <= 4_096,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.version == 1, receipt.app_build == appBuild else { return nil }
        return receipt.browsers
    }

    /// The installer may finish without an unlocked desktop. Read its bounded,
    /// root-owned receipt later without following a user-replaced link.
    static func trustedInstallerReceipt(appBuild: String) -> Self? {
        let path = "/Library/Application Support/Intent/onboarding-browser-choice.json"
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == 0,
              metadata.st_mode & 0o022 == 0, metadata.st_size > 0, metadata.st_size <= 4_096 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? file.read(upToCount: 4_097) else { return nil }
        return installerReceipt(data: data, appBuild: appBuild)
    }
}

/// Stored in the current app's defaults domain, so Test and launch never share
/// setup progress. A durable profile identity is a binding, not a live pass.
struct IntentBrowserOnboardingPreferences: Codable, Equatable {
    static let key = "intentBrowserOnboardingV1"
    var browsers: IntentSetupBrowserChoice = .both
    var selectedProfileIDs: Set<String>?
    var profileIdentities: [String: String] = [:]
    var completed = false

    static func load(defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? .init()
    }
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
    static func consumeInstallerArguments(_ arguments: [String], defaults: UserDefaults = .standard,
                                         receipt: (() -> IntentSetupBrowserChoice?)? = nil) {
        guard !defaults.bool(forKey: "intentDidCompleteOnboarding"),
              defaults.object(forKey: key) == nil else { return }
        let hasExplicitChoice = arguments.contains { $0 == "--setup-browsers" || $0.hasPrefix("--setup-browsers=") }
        guard let browsers = hasExplicitChoice
            ? IntentSetupBrowserChoice.installerChoice(arguments: arguments)
            : receipt?() else { return }
        var preferences = Self(); preferences.browsers = browsers; preferences.save(defaults: defaults)
    }
    func initialSelection(profiles: [IntentLocalBrowserProfile], preferredBrowser: IntentSetupBrowser? = nil) -> Set<String> {
        // Discovery may temporarily fail while the browser updates its metadata.
        // Only an explicit user action can remove an existing selection.
        if let selectedProfileIDs { return selectedProfileIDs }
        return Set(profiles.filter { profile in
            preferredBrowser.map { $0 == profile.browser } ?? browsers.includes(profile.browser)
        }.map(\.id))
    }
    func missingBrowsers(profiles: [IntentLocalBrowserProfile]) -> [IntentSetupBrowser] {
        IntentSetupBrowser.allCases.filter { browser in
            browsers.includes(browser) && !profiles.contains { $0.browser == browser }
        }
    }
    var browsersNeedingSelection: [IntentSetupBrowser] {
        IntentSetupBrowser.allCases.filter { browser in
            browsers.includes(browser) && !(selectedProfileIDs ?? []).contains { $0.hasPrefix(browser.rawValue + "|") }
        }
    }
    func canComplete(profiles: [IntentLocalBrowserProfile], connected: Set<String>) -> Bool {
        guard let selectedProfileIDs, !selectedProfileIDs.isEmpty,
              missingBrowsers(profiles: profiles).isEmpty, browsersNeedingSelection.isEmpty else { return false }
        return selectedProfileIDs.isSubset(of: Set(profiles.map(\.id))) && selectedProfileIDs.isSubset(of: connected)
    }
}

enum IntentProfileSetupConfirmation {
    static func isFreshChallenge(_ createdAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return age >= 0 && age <= 600
    }
    static func isFreshReceipt(_ checkedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(checkedAt)
        return age >= -0.25 && age <= 3
    }
    static func accepts(_ url: URL, scheme: String, nonce: String, createdAt: Date, now: Date) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == scheme, parts.host == "browser-setup-confirm",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.fragment == nil,
              let items = parts.queryItems, items.count == 1, items[0].name == "nonce",
              items[0].value == nonce, UUID(uuidString: nonce) != nil else { return false }
        return isFreshChallenge(createdAt, now: now)
    }
}

/// Installation evidence is deliberately separate from a live connection.
/// A heartbeat from another profile cannot certify the profile shown here.
enum IntentProfileGuardStatus: Equatable {
    case missing
    case disabled(String?)
    case outdated(String)
    case temporary(String)
    case matching(String)
    case unreadable

    var label: String {
        switch self {
        case .missing: return "Extension not installed"
        case .disabled: return "Extension switched off"
        case .outdated(let version): return "Update needed · \(version)"
        case .temporary: return "Temporary extension · permanent setup needed"
        case .matching: return "Matching extension installed"
        case .unreadable: return "Open this profile to check its extension"
        }
    }
    var isMatching: Bool { if case .matching = self { return true }; return false }
}

struct IntentLocalBrowserProfile: Identifiable, Equatable {
    let browser: IntentSetupBrowser
    let name: String
    let account: String?
    let directory: URL
    let guardStatus: IntentProfileGuardStatus
    var id: String { browser.rawValue + "|" + directory.path }
}

/// Only reads profile metadata. Never changes browser preferences, installs an
/// extension, opens a profile, or imports browser history/account data.
struct IntentBrowserProfileDiscovery {
    static let chromeStoreID = "ffgfjfpkddgimambgmahlodjjojmjnbc"
    static let chromeDevelopmentID = "aibdbhjdckeeejpggfpfaghmomopjbpb"
    static let firefoxID = "intent-firefox@loganmondi.dev"
    let applicationSupport: URL
    let requiredVersion: String
    let development: Bool
    private let fm = FileManager.default

    func discover() -> [IntentLocalBrowserProfile] {
        (chromeProfiles() + firefoxProfiles()).sorted {
            if $0.browser != $1.browser { return $0.browser.name < $1.browser.name }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func json(_ url: URL) -> [String: Any]? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private func existingDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private func chromeProfiles() -> [IntentLocalBrowserProfile] {
        let root = applicationSupport.appendingPathComponent("Google/Chrome", isDirectory: true)
        let cache = (json(root.appendingPathComponent("Local State"))?["profile"] as? [String: Any])?["info_cache"] as? [String: Any] ?? [:]
        var entries = cache
        if entries.isEmpty, existingDirectory(root.appendingPathComponent("Default")) {
            entries["Default"] = ["name": "Default"]
        }
        return entries.prefix(256).compactMap { component, raw in
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains("/"), !component.contains("\\"),
                  component != "Guest Profile", component != "System Profile" else { return nil }
            let directory = root.appendingPathComponent(component, isDirectory: true)
            guard existingDirectory(directory) else { return nil }
            let metadata = raw as? [String: Any] ?? [:]
            let name = cleaned(metadata["name"] as? String) ?? component
            return .init(browser: .chrome, name: name, account: cleaned(metadata["user_name"] as? String),
                         directory: directory, guardStatus: chromeGuard(in: directory))
        }
    }

    private func chromeGuard(in directory: URL) -> IntentProfileGuardStatus {
        let preferences = json(directory.appendingPathComponent("Preferences"))
        let secure = json(directory.appendingPathComponent("Secure Preferences"))
        guard preferences != nil || secure != nil else { return .unreadable }
        var settings = (preferences?["extensions"] as? [String: Any])?["settings"] as? [String: Any] ?? [:]
        let secureSettings = (secure?["extensions"] as? [String: Any])?["settings"] as? [String: Any] ?? [:]
        settings.merge(secureSettings) { _, new in new }
        let identifiers = development ? [Self.chromeDevelopmentID, Self.chromeStoreID] : [Self.chromeStoreID]
        var fallback: IntentProfileGuardStatus = .missing
        for identifier in identifiers {
            guard let row = settings[identifier] as? [String: Any] else { continue }
            let embedded = row["manifest"] as? [String: Any]
            let version = embedded?["version"] as? String ?? registeredChromeVersion(row, in: directory, identifier: identifier)
            let disabledReasons = row["disable_reasons"] as? [Any] ?? []
            let disabledMask = (row["disable_reasons"] as? NSNumber)?.intValue ?? 0
            let legacyState = (row["state"] as? NSNumber)?.intValue
            // Current Chrome omits state and manifest from Secure Preferences.
            // It records only disable reasons when an extension is disabled.
            guard (legacyState == nil || legacyState == 1), disabledReasons.isEmpty, disabledMask == 0 else {
                fallback = .disabled(version); continue
            }
            guard let version else { fallback = .unreadable; continue }
            if version == requiredVersion {
                if !development && (row["location"] as? NSNumber)?.intValue != 1 && row["from_webstore"] as? Bool != true { return .temporary(version) }
                return .matching(version)
            }
            fallback = .outdated(version)
        }
        return fallback
    }

    private func registeredChromeVersion(_ row: [String: Any], in directory: URL, identifier: String) -> String? {
        if let path = row["path"] as? String, !path.isEmpty {
            let folder: URL?
            if path.hasPrefix("/") {
                folder = URL(fileURLWithPath: path, isDirectory: true)
            } else if !path.components(separatedBy: "/").contains(".."), path.components(separatedBy: "/").first == identifier {
                folder = directory.appendingPathComponent("Extensions/" + path, isDirectory: true)
            } else { folder = nil }
            if let folder, let version = json(folder.appendingPathComponent("manifest.json"))?["version"] as? String { return version }
        }
        // Do not pick the newest leftover directory: it may not be the copy
        // this profile has registered or enabled.
        return nil
    }

    private func firefoxProfiles() -> [IntentLocalBrowserProfile] {
        let root = applicationSupport.appendingPathComponent("Firefox", isDirectory: true)
        let ini = root.appendingPathComponent("profiles.ini")
        guard let size = (try? ini.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1024 * 1024,
              let text = try? String(contentsOf: ini, encoding: .utf8) else { return [] }
        var sections: [[String: String]] = []
        var current: [String: String]?
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if let current { sections.append(current) }
                current = line.hasPrefix("[Profile") ? [:] : nil
            } else if !line.hasPrefix(";"), !line.hasPrefix("#"), let equals = line.firstIndex(of: "="), current != nil {
                current?[String(line[..<equals]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        if let current { sections.append(current) }
        var seen = Set<String>()
        return sections.prefix(256).compactMap { section in
            guard let path = cleaned(section["Path"]) else { return nil }
            let directory: URL
            if section["IsRelative"] == "1" {
                guard !path.hasPrefix("/"), !path.components(separatedBy: "/").contains("..") else { return nil }
                directory = root.appendingPathComponent(path, isDirectory: true).standardizedFileURL
            } else {
                guard path.hasPrefix("/") else { return nil }
                directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
            guard existingDirectory(directory), seen.insert(directory.path).inserted else { return nil }
            return .init(browser: .firefox, name: cleaned(section["Name"]) ?? directory.lastPathComponent,
                         account: nil, directory: directory, guardStatus: firefoxGuard(in: directory))
        }
    }

    private func firefoxGuard(in directory: URL) -> IntentProfileGuardStatus {
        let file = directory.appendingPathComponent("extensions.json")
        guard fm.fileExists(atPath: file.path) else { return .missing }
        guard let metadata = json(file), let addons = metadata["addons"] as? [[String: Any]] else { return .unreadable }
        guard let addon = addons.first(where: { $0["id"] as? String == Self.firefoxID }) else { return .missing }
        let version = addon["version"] as? String
        guard addon["active"] as? Bool == true, addon["userDisabled"] as? Bool != true,
              addon["appDisabled"] as? Bool != true else { return .disabled(version) }
        guard let version else { return .unreadable }
        if version != requiredVersion { return .outdated(version) }
        if !development && (addon["temporarilyInstalled"] as? Bool == true || ((addon["signedState"] as? NSNumber)?.intValue ?? 0) < 2) {
            return .temporary(version)
        }
        return .matching(version)
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

enum IntentBrowserProfileLaunchPlan: Equatable {
    case open(arguments: [String])
    case useOpenFirefoxProfile
    case chromeSetupInstructions

    static func plan(profile: IntentLocalBrowserProfile, destination: String, firefoxAlreadyOpen: Bool) -> Self {
        switch profile.browser {
        case .chrome:
            // Chrome rejects privileged chrome:// pages passed as external
            // launch arguments. They must never silently fall back to New Tab.
            if URL(string: destination)?.scheme == "chrome" { return .chromeSetupInstructions }
            return .open(arguments: ["--profile-directory=" + profile.directory.lastPathComponent, destination])
        case .firefox:
            // Firefox's remote URL forwarding does not guarantee the requested
            // profile. A new instance is safe only when that profile is closed.
            if firefoxAlreadyOpen { return .useOpenFirefoxProfile }
            return .open(arguments: ["--no-remote", "--profile", profile.directory.path, "--new-tab", destination])
        }
    }
}

/// A local, inert handoff page uses a launchable file URL. It does not pretend
/// that a web link can navigate Chrome's privileged extension-management page.
enum IntentBrowserProfileSetupPage {
    static func html(profile: IntentLocalBrowserProfile, requiredVersion: String, folder: URL) -> String {
        let name = escape(profile.name), version = escape(requiredVersion), path = escape(folder.path)
        let steps: String
        if profile.guardStatus.isMatching {
            steps = """
            <p>Browser Guard \(version) is installed in this profile.</p>
            <ol><li>Return to Intent and choose <strong>Done</strong>.</li><li>Open this profile’s tab picker in Intent to verify its live connection.</li></ol>
            <p class="muted">An installed extension alone does not confirm that its connection is working.</p>
            """
        } else {
            steps = """
            <ol><li>Press <strong>⌘L</strong>, enter <code>chrome://extensions</code>, then press <strong>Return</strong>.</li>
            <li>Turn on <strong>Developer mode</strong>, then choose <strong>Load unpacked</strong>.</li>
            <li>In the folder chooser, press <strong>⌘⇧G</strong>, paste the copied folder path, press Return, and select the folder.</li></ol>
            <p class="muted">The Chrome folder path has been copied:</p><code class="path">\(path)</code>
            <p>Then return to Intent and choose <strong>Refresh</strong>.</p>
            """
        }
        return """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Intent · Chrome profile setup</title><style>
        :root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;background:#090a0e;color:#f2f3f7;font:17px/1.65 -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;padding:36px}
        main{width:min(100%,680px)}.brand{font:36px Georgia,serif;letter-spacing:-1px}.muted{color:#a6a9b5;font-size:14px}.tag{display:inline-block;border:1px solid #414450;border-radius:30px;padding:5px 12px;margin-top:8px;color:#c6c9d2;font-size:13px}
        h1{font-size:27px;line-height:1.3;margin:32px 0 10px}li{margin:13px 0}code{font-size:15px;background:#1c1e26;border-radius:6px;padding:3px 7px}.path{display:block;overflow-wrap:anywhere;padding:12px}footer{margin-top:30px;border-top:1px solid #30323c;padding-top:17px;color:#a6a9b5;font-size:13px}
        </style><main><div class="brand">intent</div><div class="tag">Private development setup</div>
        <h1>Chrome · \(name)</h1>\(steps)
        <footer>Chrome does not accept its extensions page as an external launch address. This setup page opens in the profile you selected. Your other profiles and tabs remain untouched.</footer>
        </main></html>
        """
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// The real setup view uses this queue, so Select all and per-profile progress
/// have one owner and can be verified without launching any browser.
struct IntentBrowserProfileSetupQueue {
    private(set) var selection: Set<String>
    private(set) var attempted = Set<String>()
    init(profiles: [IntentLocalBrowserProfile] = [], preferredBrowser: IntentSetupBrowser? = nil) {
        selection = Set(profiles.filter { preferredBrowser == nil || $0.browser == preferredBrowser }.map(\.id))
    }
    func selected(from profiles: [IntentLocalBrowserProfile]) -> [IntentLocalBrowserProfile] { profiles.filter { selection.contains($0.id) } }
    func next(from profiles: [IntentLocalBrowserProfile]) -> IntentLocalBrowserProfile? { selected(from: profiles).first { !attempted.contains($0.id) } }
    mutating func selectAll(_ profiles: [IntentLocalBrowserProfile]) { selection = Set(profiles.map(\.id)); attempted = [] }
    mutating func clear() { selection = []; attempted = [] }
    mutating func setSelected(_ id: String, selected: Bool) {
        if selected { selection.insert(id) } else { selection.remove(id) }
        attempted.remove(id)
    }
    mutating func didAttempt(_ id: String) { attempted.insert(id) }
    mutating func refresh(_ profiles: [IntentLocalBrowserProfile]) { selection.formIntersection(Set(profiles.map(\.id))); attempted = [] }
}

struct IntentBrowserSetupReleaseConfiguration {
    static let chromeStoreURL = URL(string: "https://chromewebstore.google.com/detail/intent-browser-guard/ffgfjfpkddgimambgmahlodjjojmjnbc")!
    let requiredVersion: String
    let development: Bool
    let chromePublishedVersion: String?
    let firefoxSignedVersion: String?
    let firefoxPackage: URL?

    enum Destination: Equatable {
        case ready(String)
        case pending(String)
    }

    func destination(for profile: IntentLocalBrowserProfile) -> Destination {
        if profile.guardStatus.isMatching {
            return .ready(profile.browser == .chrome
                ? (development ? "chrome://extensions" : Self.chromeStoreURL.absoluteString)
                : "about:addons")
        }
        if development {
            return .ready(profile.browser == .chrome ? "chrome://extensions" : "about:debugging#/runtime/this-firefox")
        }
        switch profile.browser {
        case .chrome:
            guard chromePublishedVersion == requiredVersion else {
                return .pending("The matching Chrome extension is awaiting publication. We won’t install an older version into this profile.")
            }
            return .ready(Self.chromeStoreURL.absoluteString)
        case .firefox:
            guard firefoxSignedVersion == requiredVersion, let firefoxPackage else {
                return .pending("The matching signed Firefox extension is being prepared. Temporary add-ons are reserved for the private development version.")
            }
            return .ready(firefoxPackage.absoluteString)
        }
    }
}
