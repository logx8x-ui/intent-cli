import Darwin
import Foundation

@main
struct ChannelIsolationSpec {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if !(try value()) { throw NSError(domain: "IntentChannelIsolation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--hold-lease" {
            guard let channel = IntentBuildChannel(rawValue: CommandLine.arguments[3]) else { exit(2) }
            let lease = IntentEngineLease(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            try lease.acquire(channel: channel)
            print("ready"); fflush(stdout)
            while let command = readLine() {
                if command == "release" { break }
                if command == "active" { try lease.updateActiveSession(true); print("active"); fflush(stdout) }
                if command == "idle" { try lease.updateActiveSession(false); print("idle"); fflush(stdout) }
            }
            lease.release()
            return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("intent-channel-isolation-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for channel in [IntentBuildChannel.launch, .development] {
            try require(IntentEnvironment.channelDataDirectory(channel: channel, home: root).lastPathComponent == channel.dataDirectoryName,
                        "Each compiled channel has its own data root")
        }
        try require(IntentBuildChannel.launch.appName == "Intent" && IntentBuildChannel.development.appName == "Test Intent", "Distinct app names")
        try require(IntentBuildChannel.launch.bundleIdentifier != IntentBuildChannel.development.bundleIdentifier, "Distinct macOS identities")
        try require(IntentBuildChannel.launch.authScheme != IntentBuildChannel.development.authScheme, "Auth callbacks cannot collide")
        try require(IntentBuildChannel.launch.accountKeychainService != IntentBuildChannel.development.accountKeychainService, "Account tokens are isolated")
        try require(IntentBuildChannel.launch.calendarKeychainService != IntentBuildChannel.development.calendarKeychainService, "Calendar tokens are isolated")
        try require(IntentBuildPolicy(channel: .launch).includesCloudAccountSync && !IntentBuildPolicy(channel: .development).includesCloudAccountSync,
                    "Test cannot write launch cloud state")

        let ownerDir = root.appendingPathComponent("engine")
        let launch = IntentEngineLease(directory: ownerDir), test = IntentEngineLease(directory: ownerDir)
        let first = try launch.acquire(channel: .launch)
        try require(launch.isOwner && IntentEngineLease.currentOwner(directory: ownerDir) == first, "Live lease publishes its owner")
        try require(IntentEngineLease.nativeHostOwner(channel: .launch, directory: ownerDir) == first, "Matching helper can route")
        try require(IntentEngineLease.nativeHostOwner(channel: .development, directory: ownerDir) == nil, "Other channel's helper cannot route")
        do { try test.acquire(channel: .development); throw NSError(domain: "ExpectedBusy", code: 1) }
        catch IntentEngineLeaseError.busy(let owner) { try require(owner?.sameEngine(as: first) == true, "Busy result identifies the actual owner") }
        try launch.updateActiveSession(true)
        try require(IntentEngineLease.currentOwner(directory: ownerDir)?.activeSession == true, "Active flag is shared only for arbitration")
        try require(IntentEngineLease.ownerStillMatches(first, directory: ownerDir), "Session status changes do not replace the engine lifetime")
        try launch.updateActiveSession(false)
        launch.release()
        try require(IntentEngineLease.currentOwner(directory: ownerDir) == nil && !launch.isOwner, "Release clears owner and lock")
        let second = try test.acquire(channel: .development)
        try require(second.generation != first.generation && !IntentEngineLease.ownerStillMatches(first, directory: ownerDir), "Handoff invalidates old native connections")
        try require(IntentEngineLease.nativeHostOwner(channel: .launch, directory: ownerDir) == nil, "Default launch fallback is denied while Test owns transport")
        test.release()
        try JSONEncoder().encode(second).write(to: ownerDir.appendingPathComponent("owner.json"))
        try require(IntentEngineLease.currentOwner(directory: ownerDir) == nil, "A stale owner record without the lock is never authoritative")
        let recovered = try launch.acquire(channel: .launch)
        try require(recovered.generation != second.generation, "Crash recovery creates a new lifetime")
        launch.release()

        let source = root.appendingPathComponent(".intent"), destination = root.appendingPathComponent(".intent-test")
        try fm.createDirectory(at: source.appendingPathComponent("backgrounds"), withIntermediateDirectories: true)
        try Data("original saved intentions".utf8).write(to: source.appendingPathComponent("intentions.json"))
        let journal: [String: Any] = ["records": [["id": "completed", "endedAt": 32.0, "remainingSeconds": 19.0],
                                                 ["id": "still-running", "remainingSeconds": 400.0]],
                                      "recovery": ["id": "active-recovery"], "slotOrder": ["saved-setup"],
                                      "workspaces": ["saved-setup": ["windows": [], "tabs": []]], "workSchedules": []]
        try JSONSerialization.data(withJSONObject: journal).write(to: source.appendingPathComponent("session-journal.json"))
        try Data("background".utf8).write(to: source.appendingPathComponent("backgrounds/custom-background.png"))
        for filename in ["browser-rules.json", "hidden-workspace.json", "browser-tabs-org-mozilla-firefox.json", "browser-tab-command-org-mozilla-firefox.json", "account-token.json", "zero-drift.json", "saved-workspace-restore-claims.json"] {
            try Data("must stay in launch".utf8).write(to: source.appendingPathComponent(filename))
        }
        let profile = source.appendingPathComponent("accounts/local-account")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("account saved intentions".utf8).write(to: profile.appendingPathComponent("intentions.json"))
        try Data("private sync cache".utf8).write(to: profile.appendingPathComponent("account-workspace.json"))
        let outside = root.appendingPathComponent("outside-secret")
        try Data("never follow".utf8).write(to: outside)
        try fm.createSymbolicLink(at: source.appendingPathComponent("always-blocked-apps.json"), withDestinationURL: outside)
        let suiteName = "dev.loganmondi.intent.qa.channel-seed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences: [String: Any] = ["quickModificationOrder": ["stopwatch", "timer"], "overviewNotesX": 12.0,
                                        "intentAccountToken": "never copy", "intentDidCompleteOnboarding": true,
                                        "intentBrowserHostBuild": "stale", "intentLaunchAtLogin": true]
        try IntentChannelSeed.seed(from: source, to: destination, preferences: preferences, defaults: defaults)
        try require(try String(contentsOf: destination.appendingPathComponent("intentions.json")) == "original saved intentions", "Saved setups copied once")
        try require(fm.fileExists(atPath: destination.appendingPathComponent("session-journal.json").path), "Recent history remains available")
        let copiedJournal = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("session-journal.json"))) as! [String: Any]
        let copiedRecords = copiedJournal["records"] as! [[String: Any]]
        try require(copiedJournal["recovery"] == nil && copiedRecords.count == 1 && copiedRecords[0]["id"] as? String == "completed", "Recovery and unfinished launch sessions never seed Test")
        try require(copiedRecords[0]["remainingSeconds"] == nil, "Completed history never carries a running timer")
        try require(copiedJournal["slotOrder"] as? [String] == ["saved-setup"] && (copiedJournal["workspaces"] as? [String: Any])?["saved-setup"] != nil, "Saved slot order and replay workspaces survive")
        try require(fm.fileExists(atPath: destination.appendingPathComponent("accounts/local-account/intentions.json").path), "Durable account workspace copied without authentication")
        try require(!fm.fileExists(atPath: destination.appendingPathComponent("accounts/local-account/account-workspace.json").path), "Remote sync ownership cache excluded")
        for filename in ["browser-rules.json", "hidden-workspace.json", "browser-tabs-org-mozilla-firefox.json", "browser-tab-command-org-mozilla-firefox.json", "account-token.json", "zero-drift.json", "saved-workspace-restore-claims.json", "always-blocked-apps.json"] {
            try require(!fm.fileExists(atPath: destination.appendingPathComponent(filename).path), "Session effects, credentials, transport and symlinks excluded: \(filename)")
        }
        try require(defaults.stringArray(forKey: "quickModificationOrder") == ["stopwatch", "timer"], "User modifier order copied")
        try require(defaults.object(forKey: "intentAccountToken") == nil && defaults.object(forKey: "intentBrowserHostBuild") == nil,
                    "Auth and browser ownership preferences not copied")
        try require(!defaults.bool(forKey: "intentDidCompleteOnboarding") && !defaults.bool(forKey: "intentLaunchAtLogin"), "Test needs own OS permissions and never starts at login from copied preference")
        try require(defaults.bool(forKey: "intentAccountChoiceMade"), "Test starts locally without an unnecessary cloud sign-in")
        try Data("test edits".utf8).write(to: destination.appendingPathComponent("intentions.json"))
        try Data("launch edits".utf8).write(to: source.appendingPathComponent("intentions.json"))
        defaults.set(["checklist"], forKey: "quickModificationOrder")
        try IntentChannelSeed.seed(from: source, to: destination, preferences: preferences, defaults: defaults)
        try require(try String(contentsOf: destination.appendingPathComponent("intentions.json")) == "test edits", "Later Test edits never overwritten by launch")
        try require(try String(contentsOf: source.appendingPathComponent("intentions.json")) == "launch edits", "Later launch edits remain independent")
        try require(defaults.stringArray(forKey: "quickModificationOrder") == ["checklist"], "Seeding never reapplies preferences on later launches")
        let link = root.appendingPathComponent("symlink-test-root")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        do { try IntentChannelSeed.seed(from: source, to: link, preferences: [:], defaults: defaults); throw NSError(domain: "ExpectedUnsafePath", code: 1) }
        catch IntentEngineLeaseError.invalidDirectory {}
        print("Separate channel identities, engine arbitration, stale-host rejection and one-time seed regressions passed.")
    }
}
