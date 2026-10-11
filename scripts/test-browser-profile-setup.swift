import Foundation

@main
struct BrowserProfileSetupSpec {
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("intent-browser-profile-spec-" + UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let support = fixture.appendingPathComponent("Application Support")
        let chrome = support.appendingPathComponent("Google/Chrome")
        let firefox = support.appendingPathComponent("Firefox")
        let required = "0.2.43"
        func directory(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        func write(_ object: [String: Any], _ file: URL) throws {
            try directory(file.deletingLastPathComponent())
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        }
        func chromePreferences(_ rows: [String: Any], _ component: String, secure: Bool = false) throws {
            try write(["extensions": ["settings": rows]], chrome.appendingPathComponent(component + (secure ? "/Secure Preferences" : "/Preferences")))
        }
        let store = IntentBrowserProfileDiscovery.chromeStoreID
        let dev = IntentBrowserProfileDiscovery.chromeDevelopmentID
        let guardRow: [String: Any] = ["state": 1, "location": 1, "manifest": ["version": required]]
        try write(["profile": ["info_cache": [
            "Default": ["name": "Personal", "user_name": "person@example.invalid"],
            "Profile 1": ["name": "Work"],
            "Guest Profile": ["name": "Guest"],
            "../escape": ["name": "Invalid"],
            "Deleted": ["name": "Old profile"]
        ]]], chrome.appendingPathComponent("Local State"))
        try directory(chrome.appendingPathComponent("Guest Profile"))
        try chromePreferences([store: guardRow], "Default")
        try chromePreferences([dev: guardRow], "Profile 1")
        let launch = IntentBrowserProfileDiscovery(applicationSupport: support, requiredVersion: required, development: false)
        let development = IntentBrowserProfileDiscovery(applicationSupport: support, requiredVersion: required, development: true)
        var profiles = launch.discover()
        precondition(profiles.count == 2, "Do not invent deleted, guest, or escaping Chrome profiles")
        precondition(profiles.first?.name == "Personal" && profiles.first?.account == "person@example.invalid")
        precondition(profiles[0].guardStatus == .matching(required), "Launch accepts the exact enabled store extension")
        precondition(profiles[1].guardStatus == .missing, "An unpacked development extension does not satisfy launch setup")
        precondition(development.discover()[1].guardStatus == .matching(required))
        precondition(profiles[0].guardStatus.label == "Matching extension installed", "Installed metadata must never claim live Connected")

        try chromePreferences([store: ["state": 0, "manifest": ["version": required]]], "Default", secure: true)
        precondition(launch.discover()[0].guardStatus == .disabled(required), "Protected preferences override an old enabled entry")
        try chromePreferences([store: ["state": 1, "location": 4, "manifest": ["version": required]]], "Default", secure: true)
        precondition(launch.discover()[0].guardStatus == .temporary(required), "An unpacked copy under the store ID is not permanent setup")
        try chromePreferences([store: ["state": 1, "location": 1, "manifest": ["version": "0.2.14"]]], "Default", secure: true)
        precondition(launch.discover()[0].guardStatus == .outdated("0.2.14"))
        try chromePreferences([store: guardRow], "Default", secure: true)
        let unpacked = fixture.appendingPathComponent("development-guard")
        try write(["version": required], unpacked.appendingPathComponent("manifest.json"))
        try chromePreferences([dev: ["location": 4, "path": unpacked.path]], "Profile 1", secure: true)
        precondition(development.discover()[1].guardStatus == .matching(required),
                     "Current Chrome omits state/manifest and refers to its registered path")
        try chromePreferences([dev: ["location": 4, "path": unpacked.path, "disable_reasons": 2]], "Profile 1", secure: true)
        precondition(development.discover()[1].guardStatus == .disabled(required), "Numeric disable reasons must be honored")
        try chromePreferences([dev: ["location": 4, "path": unpacked.path, "disable_reasons": [2]]], "Profile 1", secure: true)
        precondition(development.discover()[1].guardStatus == .disabled(required), "Array disable reasons must be honored")
        try chromePreferences([dev: ["location": 4, "path": unpacked.appendingPathComponent("missing").path]], "Profile 1", secure: true)
        precondition(development.discover()[1].guardStatus == .unreadable, "Missing active source must not be guessed from stale directories")
        try chromePreferences([dev: ["location": 4, "path": unpacked.path]], "Profile 1", secure: true)

        try directory(firefox.appendingPathComponent("Profiles/study"))
        try directory(firefox.appendingPathComponent("Profiles/test"))
        try directory(firefox.appendingPathComponent("Profiles/old"))
        let custom = fixture.appendingPathComponent("custom-firefox")
        try directory(custom)
        let ini = """
        [General]
        StartWithLastProfile=1
        [Profile0]
        Name=Study
        IsRelative=1
        Path=Profiles/study
        [Profile1]
        Name=Temporary
        IsRelative=1
        Path=Profiles/test
        [Profile2]
        Name=Old
        IsRelative=1
        Path=Profiles/old
        [Profile3]
        Name=Custom
        IsRelative=0
        Path=\(custom.path)
        [Profile4]
        Name=Escape
        IsRelative=1
        Path=../escape
        [Profile5]
        Name=Duplicate
        IsRelative=1
        Path=Profiles/study
        """
        try ini.write(to: firefox.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        func firefoxAddon(_ folder: URL, version: String = required, temporary: Bool = false, active: Bool = true) throws {
            try write(["addons": [["id": IntentBrowserProfileDiscovery.firefoxID, "version": version,
                                  "active": active, "signedState": 2, "temporarilyInstalled": temporary]]],
                      folder.appendingPathComponent("extensions.json"))
        }
        try firefoxAddon(firefox.appendingPathComponent("Profiles/study"))
        try firefoxAddon(firefox.appendingPathComponent("Profiles/test"), temporary: true)
        try firefoxAddon(firefox.appendingPathComponent("Profiles/old"), version: "0.2.42")
        profiles = launch.discover()
        let firefoxRows = profiles.filter { $0.browser == .firefox }
        precondition(firefoxRows.count == 4, "Discover declared absolute profiles, ignore duplicates and escaping relative paths")
        let study = firefoxRows.first { $0.name == "Study" }!
        precondition(study.guardStatus == .matching(required))
        precondition(firefoxRows.first { $0.name == "Temporary" }?.guardStatus == .temporary(required))
        precondition(firefoxRows.first { $0.name == "Old" }?.guardStatus == .outdated("0.2.42"))
        precondition(firefoxRows.first { $0.name == "Custom" }?.guardStatus == .missing)
        try firefoxAddon(firefox.appendingPathComponent("Profiles/study"), active: false)
        precondition(launch.discover().first { $0.name == "Study" }?.guardStatus == .disabled(required))
        try Data("not valid json".utf8).write(to: custom.appendingPathComponent("extensions.json"))
        precondition(launch.discover().first { $0.name == "Custom" }?.guardStatus == .unreadable)

        let missingChrome = profiles.first { $0.name == "Work" }!
        var queue = IntentBrowserProfileSetupQueue(profiles: profiles)
        precondition(queue.selection.count == profiles.count, "No preference means recommend both browsers/all local profiles")
        queue.clear()
        precondition(queue.next(from: profiles) == nil)
        queue.selectAll(profiles)
        var visited = Set<String>()
        while let next = queue.next(from: profiles) { visited.insert(next.id); queue.didAttempt(next.id) }
        precondition(visited == Set(profiles.map(\.id)), "Select all visits each profile exactly once without browser launches")
        queue.refresh(profiles)
        precondition(queue.next(from: profiles)?.id == profiles.first?.id, "Refresh allows setup or status checks to retry")
        queue.setSelected(profiles[0].id, selected: false)
        precondition(queue.next(from: profiles)?.id == profiles[1].id, "Deselected profiles are never opened")
        queue.refresh(Array(profiles.dropFirst(2)))
        precondition(!queue.selection.contains(profiles[1].id), "A deleted profile is removed from the queue")
        let chromeOnly = IntentBrowserProfileSetupQueue(profiles: profiles, preferredBrowser: .chrome)
        precondition(chromeOnly.selected(from: profiles).allSatisfy { $0.browser == .chrome }, "A browser-specific onboarding action keeps its requested scope")
        let pending = IntentBrowserSetupReleaseConfiguration(requiredVersion: required, development: false,
            chromePublishedVersion: "0.2.14", firefoxSignedVersion: "0.2.42", firefoxPackage: custom.appendingPathComponent("guard.xpi"))
        guard case .pending = pending.destination(for: missingChrome) else { preconditionFailure("Never offer an outdated store build") }
        let missingFirefox = firefoxRows.first { $0.name == "Custom" }!
        guard case .pending = pending.destination(for: missingFirefox) else { preconditionFailure("Never offer a stale signed Firefox artifact") }
        let released = IntentBrowserSetupReleaseConfiguration(requiredVersion: required, development: false,
            chromePublishedVersion: required, firefoxSignedVersion: required, firefoxPackage: custom.appendingPathComponent("guard.xpi"))
        precondition(released.destination(for: missingChrome) == .ready(IntentBrowserSetupReleaseConfiguration.chromeStoreURL.absoluteString))
        precondition(released.destination(for: missingFirefox) == .ready(custom.appendingPathComponent("guard.xpi").absoluteString))
        let privateConfig = IntentBrowserSetupReleaseConfiguration(requiredVersion: required, development: true,
            chromePublishedVersion: nil, firefoxSignedVersion: nil, firefoxPackage: nil)
        precondition(privateConfig.destination(for: missingChrome) == .ready("chrome://extensions"))
        precondition(privateConfig.destination(for: missingFirefox) == .ready("about:debugging#/runtime/this-firefox"))
        let matchingChrome = IntentLocalBrowserProfile(browser: .chrome, name: "Study <script> & \"work\"", account: nil,
            directory: missingChrome.directory, guardStatus: .matching(required))
        precondition(released.destination(for: matchingChrome) == .ready(IntentBrowserSetupReleaseConfiguration.chromeStoreURL.absoluteString),
            "A matching launch profile still opens the supported HTTPS store page, never a rejected chrome:// launch URL")
        precondition(IntentBrowserProfileLaunchPlan.plan(profile: missingChrome, destination: "chrome://extensions", firefoxAlreadyOpen: false)
            == .chromeSetupInstructions, "Chrome internal pages must route to a real local instruction page rather than silently opening New Tab")
        let matchingHTML = IntentBrowserProfileSetupPage.html(profile: matchingChrome, requiredVersion: required,
            folder: URL(fileURLWithPath: "/tmp/Chrome <folder> & files"))
        precondition(matchingHTML.contains("Study &lt;script&gt; &amp; &quot;work&quot;") && !matchingHTML.contains("Study <script>"))
        precondition(!matchingHTML.contains("Load unpacked"), "A matching development guard must not be told to reinstall")
        let missingHTML = IntentBrowserProfileSetupPage.html(profile: missingChrome, requiredVersion: required,
            folder: URL(fileURLWithPath: "/tmp/Chrome <folder> & files"))
        precondition(missingHTML.contains("Load unpacked") && missingHTML.contains("Chrome &lt;folder&gt; &amp; files"))
        precondition(!missingHTML.contains("href=\"chrome:"), "A web link cannot pretend to navigate Chrome's privileged page")
        let localPage = URL(fileURLWithPath: "/tmp/Intent profile setup.html").absoluteString
        precondition(IntentBrowserProfileLaunchPlan.plan(profile: missingChrome, destination: localPage, firefoxAlreadyOpen: false)
            == .open(arguments: ["--profile-directory=Profile 1", localPage]), "The local guide must keep the exact profile and encoded file URL")

        precondition(IntentBrowserProfileLaunchPlan.plan(profile: missingChrome, destination: "https://example.invalid", firefoxAlreadyOpen: false)
                     == .open(arguments: ["--profile-directory=Profile 1", "https://example.invalid"]))
        precondition(IntentBrowserProfileLaunchPlan.plan(profile: study, destination: "about:addons", firefoxAlreadyOpen: true) == .useOpenFirefoxProfile,
                     "Do not route into a guessed Firefox profile or start a locked profile")
        precondition(IntentBrowserProfileLaunchPlan.plan(profile: study, destination: "about:addons", firefoxAlreadyOpen: false)
                     == .open(arguments: ["--no-remote", "--profile", study.directory.path, "--new-tab", "about:addons"]))
        print("Browser profile discovery, permanent-install readiness, and exact-profile routing spec passed")
    }
}
