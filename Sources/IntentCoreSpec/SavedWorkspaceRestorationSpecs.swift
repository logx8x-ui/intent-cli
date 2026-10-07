import Foundation
import IntentCore
import IntentLock

func runSavedWorkspaceRestorationSpecs() throws {
    let browser = "com.google.Chrome"
    let profileA = "5BD08060-9E6B-4C23-91F8-EE84344F173E"
    let profileB = "3C769177-B556-45A7-866A-571BA5FBFF79"
    let app = AllowedApp(name: "Chrome", bundleIdentifier: browser)
    func row(_ id: Int, _ url: String = "https://example.com/work", title: String = "Work", window: Int = 10, container: String? = nil) -> BrowserTabItem {
        .init(id: id, windowID: window, index: id, title: title, url: url, active: id == 3, cookieStoreID: container)
    }
    func snapshot(_ rows: [BrowserTabItem], session: String = "original", profile: String? = nil) -> BrowserTabSnapshot {
        .init(browserBundleIdentifier: browser, browserSessionID: session, browserProfileID: profile ?? profileA, tabs: rows, allTabs: rows)
    }
    func workspace(ids: [Int], mode: IntentionAccessMode = .whitelist) -> SessionWorkspace {
        var selected = QuickSelection(); selected.accessMode = mode
        for id in ids { selected.toggleTab(.init(browser: browser, id: id), browserSessionID: "original") }
        return .init(selection: selected, windows: [], tabs: ids.map {
            .init(browser: browser, url: "https://example.com/work", title: "Old title", profileID: profileA,
                  sessionID: "original", nativeID: $0, windowID: 10)
        })
    }
    func plan(_ workspace: SessionWorkspace, _ profiles: [BrowserTabSnapshot]) -> SessionWorkspace.Resolution {
        workspace.restorationPlan(runningApps: [browser], windows: [], profiles: profiles)
    }
    let one = workspace(ids: [1])
    let changed = plan(one, [snapshot([row(1, "https://redirected.example/new", title: "New title")])])
    try expect(changed.missing == 0 && changed.pendingTabs.isEmpty && changed.selection.tabIDsByBrowser[browser] == [1],
        "Existing same-lifetime tab survives title, URL, hash and redirect changes without reload or creation")
    let titleOnly = plan(one, [snapshot([row(99, title: "Changed after restart")], session: "restarted")])
    try expect(titleOnly.missing == 0 && titleOnly.selection.tabIDsByBrowser[browser] == [99],
        "After restart the saved profile reuses a unique exact URL independent of title")
    let duplicate = workspace(ids: [1, 2])
    let partial = plan(duplicate, [snapshot([row(1), row(3, "https://other.example")])])
    try expect(partial.missing == 0 && partial.selection.tabIDsByBrowser[browser] == [1] && partial.pendingTabs.count == 1,
        "Two saved duplicate tabs never collapse onto one existing tab")
    try expect(partial.pendingTabs[0].descriptor.nativeID == 2 && partial.pendingTabs[0].ownerSessionID == "original",
        "Only the missing duplicate is staged for its original profile")
    var separateWindows = duplicate
    separateWindows.tabs[1].windowID = 20
    let survivingSecond = plan(separateWindows, [snapshot([row(3, "https://anchor.example", window: 10), row(2, window: 20)])])
    try expect(survivingSecond.missing == 0 && survivingSecond.selection.tabIDsByBrowser[browser] == [2]
        && survivingSecond.pendingTabs.count == 1 && survivingSecond.pendingTabs[0].descriptorIndex == 0
        && survivingSecond.pendingTabs[0].descriptor.nativeID == 1 && survivingSecond.pendingTabs[0].windowID == 10
        && survivingSecond.pendingTabs[0].anchorTabID == 3,
        "A missing first duplicate cannot borrow the later exact tab; restore only the first in its original window")
    let extraDuplicateCandidates = plan(separateWindows, [snapshot([row(3, "https://anchor.example"), row(2, window: 20), row(30), row(40)])])
    try expect(extraDuplicateCandidates.missing == 1 && extraDuplicateCandidates.pendingTabs.isEmpty
        && extraDuplicateCandidates.selection.tabIDsByBrowser[browser] == [2],
        "A reserved survivor cannot inflate the count of missing duplicates and hide ambiguous URL replacements")
    let recycledDuplicateIDs = plan(duplicate, [snapshot([row(1), row(2)], session: "restarted")])
    try expect(recycledDuplicateIDs.missing == 0 && recycledDuplicateIDs.pendingTabs.isEmpty
        && recycledDuplicateIDs.selection.tabIDsByBrowser[browser] == [1, 2],
        "Old numeric IDs are not reserved after restart; the verified profile can still reuse the exact URL multiplicity")
    let duplicatesAfterRestart = plan(duplicate, [snapshot([row(30), row(40)], session: "new")])
    try expect(duplicatesAfterRestart.missing == 0 && duplicatesAfterRestart.selection.tabIDsByBrowser[browser] == [30, 40],
        "Duplicate URL fallback consumes each matching tab once")
    let ambiguous = plan(one, [snapshot([row(30), row(40)], session: "new")])
    try expect(ambiguous.missing == 1 && ambiguous.pendingTabs.isEmpty && ambiguous.selection.tabs.isEmpty,
        "One saved tab cannot silently select one of two indistinguishable replacements")
    let recycled = plan(one, [snapshot([row(1, "https://unrelated.example"), row(3, "https://anchor.example")], session: "new")])
    try expect(recycled.selection.tabs.isEmpty && recycled.pendingTabs.count == 1,
        "A recycled browser ID after restart never selects unrelated content")
    let profiles = [snapshot([row(1)], session: "new-a"), snapshot([row(1)], session: "new-b", profile: profileB)]
    let properProfile = plan(one, profiles)
    try expect(properProfile.missing == 0 && properProfile.selection.tabIDsByBrowser[browser] == [BrowserProfileSnapshots.compositeID(session: "new-a", id: 1)],
        "Identical URL in another profile is never substituted for the saved profile")
    let clonedIdentity = plan(one, [snapshot([row(1)], session: "copy-a"), snapshot([row(2)], session: "copy-b")])
    try expect(clonedIdentity.missing == 1 && clonedIdentity.pendingTabs.isEmpty,
        "Cloned extension profile UUIDs remain ambiguous rather than choosing an account")
    let closed = plan(one, [])
    try expect(closed.missing == 1 && closed.pendingTabs.isEmpty && closed.selection.apps.isEmpty,
        "A closed/unreported saved profile cannot launch a guessed default profile")
    let multipleWindows = plan(one, [snapshot([row(3, "https://anchor.example"), row(4, "https://other.example", window: 20)], session: "new")])
    try expect(multipleWindows.missing == 1 && multipleWindows.pendingTabs.isEmpty,
        "After restart a missing tab needs a positively identified destination window")
    let existingWindow = plan(one, [snapshot([row(3, "https://anchor.example"), row(4, "https://other.example", window: 20)])])
    try expect(existingWindow.missing == 0 && existingWindow.pendingTabs.first?.windowID == 10,
        "A missing tab retains its live original window even when another window exists")
    let blocked = plan(workspace(ids: [1, 2], mode: .blacklist), [snapshot([row(1), row(3, "https://anchor.example")])])
    try expect(blocked.missing == 0 && blocked.pendingTabs.isEmpty && blocked.selection.tabIDsByBrowser[browser] == [1],
        "Blacklist reuses existing blocked tabs and never schedules creation for a missing target")
    let blockedUnknown = plan(workspace(ids: [1], mode: .blacklist), [])
    try expect(blockedUnknown.missing == 1 && blockedUnknown.pendingTabs.isEmpty,
        "Disconnected blocked profile is unresolved, not proof that the blocked tab is absent")
    let blockedIntention = try blocked.selection.makeIntention(apps: [app], snapshots: [snapshot([row(1), row(3)])])
    try expect(IntentionStartupPlanner.steps(for: blockedIntention).isEmpty, "Blacklist restoration has zero startup launches")
    var internalTab = one
    internalTab.tabs[0].url = "chrome://settings/"
    let internalMissing = plan(internalTab, [snapshot([row(3, "https://anchor.example")])])
    try expect(internalMissing.missing == 1 && internalMissing.pendingTabs.isEmpty,
        "Missing privileged/internal pages are not sent to the web-tab creation API")
    var container = one; container.tabs[0].cookieStoreID = "firefox-container-2"
    let wrongContainer = plan(container, [snapshot([row(1, container: "firefox-container-1"), row(3, "https://anchor.example", container: "firefox-container-1")])])
    try expect(wrongContainer.missing == 1 && wrongContainer.pendingTabs.isEmpty && wrongContainer.selection.tabs.isEmpty,
        "Container identity cannot silently become the default container")
    var legacy = one; legacy.tabs = [.init(browser: browser, url: "https://example.com/work", title: "Old title")]
    let legacyUnique = plan(legacy, [snapshot([row(99, title: "Changed")], session: "new")])
    try expect(legacyUnique.missing == 1 && legacyUnique.selection.tabs.isEmpty, "Legacy URL cannot borrow a sole connected profile after its saved lifetime disappeared")
    let legacyAmbiguous = plan(legacy, profiles)
    try expect(legacyAmbiguous.missing == 1 && legacyAmbiguous.pendingTabs.isEmpty, "Legacy multi-profile saves require identity recovery")
    var freshLegacyOwner = snapshot([row(99, title: "Changed")], session: "new")
    freshLegacyOwner.profileDiscoveryRequestIDs = [UUID().uuidString]
    let migrated = legacy.restorationPlan(runningApps: [browser], windows: [], profiles: [freshLegacyOwner], allowLegacyProfileMigration: true)
    try expect(migrated.missing == 0 && migrated.selection.tabIDsByBrowser[browser] == [99]
        && migrated.replayWorkspace.tabs[0].profileID == profileA && migrated.replayWorkspace.tabs[0].nativeID == 99,
        "Identity-free legacy preset migrates a sole freshly confirmed owner and immediately records durable replay identity")
    var freshMissing = freshLegacyOwner; freshMissing.tabs = [row(3, "https://anchor.example")]; freshMissing.allTabs = freshMissing.tabs
    let migratedMissing = legacy.restorationPlan(runningApps: [browser], windows: [], profiles: [freshMissing], allowLegacyProfileMigration: true)
    try expect(migratedMissing.missing == 0 && migratedMissing.pendingTabs.count == 1 && migratedMissing.pendingTabs[0].windowID == 10,
        "A confirmed missing legacy website stages exactly once in the sole verified browser window")
    let migrationAmbiguous = legacy.restorationPlan(runningApps: [browser], windows: [], profiles: [freshLegacyOwner, profiles[1]], allowLegacyProfileMigration: true)
    try expect(migrationAmbiguous.missing == 1 && migrationAmbiguous.pendingTabs.isEmpty,
        "Legacy migration never chooses between two connected browser profiles")
    var staleMigration = freshMissing; staleMigration.updatedAt = Date().addingTimeInterval(-10)
    try expect(legacy.restorationPlan(runningApps: [browser], windows: [], profiles: [staleMigration], allowLegacyProfileMigration: true).missing == 1,
        "Legacy migration rejects stale inventory even if the caller opts into migration")
    var wrongKnownProfile = one; wrongKnownProfile.tabs[0].profileID = profileB
    try expect(wrongKnownProfile.restorationPlan(runningApps: [browser], windows: [], profiles: [freshLegacyOwner], allowLegacyProfileMigration: true).missing == 1,
        "The legacy migration path cannot replace a known saved profile with the current sole profile")
    var twoWindowLegacy = freshMissing; twoWindowLegacy.allTabs?.append(row(4, "https://other.example", window: 20))
    try expect(legacy.restorationPlan(runningApps: [browser], windows: [], profiles: [twoWindowLegacy], allowLegacyProfileMigration: true).pendingTabs.isEmpty,
        "A missing legacy tab cannot guess between multiple destination windows")

    // Review edits operate on refreshed resource identities while retaining
    // missing targets the user has not removed; B never changes their scope.
    let staged = partial.replayWorkspace
    let visible = SessionWorkspace(selection: partial.selection, windows: [], tabs: [staged.tabs[0]])
    var editedVisible = visible; editedVisible.selection.apps.insert("com.example.notes")
    editedVisible.selection.restrictionNodes = [.init(kind: .timer, position: .zero, durationMinutes: 7, showsRemainingTime: true, locksSessionUntilTimerEnds: true)]
    let editedStage = staged.reconcilingSelection(previous: visible, current: editedVisible)
    let editedPlan = plan(editedStage, [snapshot([row(1), row(3, "https://other.example")])])
    try expect(editedStage.tabs.count == 2 && editedPlan.pendingTabs.count == 1 && editedStage.selection.apps.contains("com.example.notes")
        && editedStage.selection.restrictionNodes.first?.durationMinutes == 7,
        "Adding another app preserves the unrelated missing saved tab and the user's edited timer")
    var unchecked = visible; unchecked.selection.tabs = []; unchecked.selection.apps.remove(browser); unchecked.tabs = []
    let pendingOnly = staged.reconcilingSelection(previous: visible, current: unchecked)
    try expect(pendingOnly.tabs.count == 1 && pendingOnly.tabs[0].nativeID == 2 && pendingOnly.selection.apps.contains(browser)
        && (pendingOnly.selection.wholeBrowserApps ?? []).isEmpty,
        "Unchecking the live tab preserves a different pending tab without granting whole-browser access")
    let blockStage = staged.restorationPlan(runningApps: [browser], windows: [], profiles: [snapshot([row(1), row(3, "https://other.example")])], accessMode: .blacklist)
    let allowAgain = blockStage.replayWorkspace.restorationPlan(runningApps: [browser], windows: [], profiles: [snapshot([row(1), row(3, "https://other.example")])], accessMode: .whitelist)
    try expect(blockStage.selection.accessMode == .blacklist && blockStage.pendingTabs.isEmpty
        && allowAgain.selection.accessMode == .whitelist && allowAgain.pendingTabs.count == 1,
        "Allow to Block to Allow replans the same pending resources; Block never creates and does not erase the pending descriptor")
    var removedBrowser = staged; removedBrowser.removeResources(for: browser)
    try expect(removedBrowser.tabs.isEmpty && !removedBrowser.selection.apps.contains(browser),
        "An explicit whole-browser removal also removes that browser's pending saved targets")
    var wholeBrowser = visible; wholeBrowser.selection.wholeBrowserApps = [browser]
    let explicitWhole = staged.reconcilingSelection(previous: visible, current: wholeBrowser)
    try expect(explicitWhole.tabs.count == 1 && explicitWhole.selection.wholeBrowserApps == [browser],
        "Only an explicit whole-browser choice replaces its pending tab scope")
    var pendingOnlyVisible = SessionWorkspace(selection: pendingOnly.selection, windows: [], tabs: [])
    let beforeWholeChoice = pendingOnlyVisible
    pendingOnlyVisible.selection.wholeBrowserApps = [browser]
    let pendingReplaced = pendingOnly.reconcilingSelection(previous: beforeWholeChoice, current: pendingOnlyVisible)
    let replacedPlan = plan(pendingReplaced, [snapshot([row(3, "https://anchor.example")])])
    try expect(beforeWholeChoice.selection.apps == pendingOnlyVisible.selection.apps
        && beforeWholeChoice.selection.tabs == pendingOnlyVisible.selection.tabs
        && pendingReplaced.tabs.isEmpty && replacedPlan.pendingTabs.isEmpty && replacedPlan.missing == 0,
        "A pending-only browser's explicit whole-app choice replaces its missing URL even when app membership and live tab IDs do not change")


    try expect(legacy.browsersToLaunchOnRun(runningApps: [], installedApps: [browser], accessMode: .whitelist) == [browser],
        "With no browser running, explicit Run plans the required installed browser application")
    try expect(legacy.browsersToLaunchOnRun(runningApps: [browser], installedApps: [browser], accessMode: .whitelist).isEmpty,
        "An already-running browser is reused, never relaunched for a saved website")
    try expect(legacy.browsersToLaunchOnRun(runningApps: [], installedApps: [browser], accessMode: .blacklist).isEmpty,
        "A closed blacklisted browser is never launched merely to block its saved tab")
    try expect(legacy.browsersToLaunchOnRun(runningApps: [], installedApps: [], accessMode: .whitelist).isEmpty,
        "Run never launches an unknown/uninstalled browser identity")

    let encoded = try JSONEncoder().encode(one)
    let decoded = try JSONDecoder().decode(SessionWorkspace.self, from: encoded)
    try expect(decoded.tabs == one.tabs, "Saved profile/lifetime/raw IDs survive persistence")
    let oldJSON = #"{"selection":{"name":"old","accessMode":"whitelist","apps":[],"tabs":[],"windowIDsByApp":{},"browserSessionIDs":{},"browserWindowTabs":[],"ranges":[],"restrictionNodes":[],"frictionNodes":[]},"windows":[],"tabs":[{"browser":"com.google.Chrome","url":"https://example.com","title":"old"}]}"#
    // Decode the descriptor separately; old selection dictionary encoding varies
    // by compiler, while every added descriptor field must be independently optional.
    let oldObject = try JSONSerialization.jsonObject(with: Data(oldJSON.utf8)) as! [String: Any]
    let oldTabs = try JSONDecoder().decode([SessionWorkspace.Tab].self, from: JSONSerialization.data(withJSONObject: oldObject["tabs"]!))
    try expect(oldTabs.first?.profileID == nil && oldTabs.first?.nativeID == nil, "Old saved tab descriptors decode without invented identity")

    var nativeSelection = QuickSelection(); nativeSelection.toggleWindow(5, app: "notes")
    let proof = BrowserProcessIdentity(pid: 7, launched: 100)
    let native = SessionWorkspace(selection: nativeSelection, windows: [.init(app: "notes", title: "Old", nativeID: 5, process: proof)], tabs: [])
    let sameWindow = native.restorationPlan(runningApps: ["notes"], windows: [.init(id: 5, app: "notes", title: "Renamed", process: proof)], profiles: [])
    try expect(sameWindow.missing == 0 && sameWindow.selection.windowIDsByApp["notes"] == [5], "Native window title changes retain exact process-lifetime identity")
    let recycledWindow = native.restorationPlan(runningApps: ["notes"], windows: [.init(id: 5, app: "notes", title: "Different", process: .init(pid: 7, launched: 101))], profiles: [])
    try expect(recycledWindow.missing == 1 && recycledWindow.selection.windowIDsByApp.isEmpty, "Recycled native IDs never inherit the old window allowance")

    // An inventory is proof for one exact request and profile, not a merged
    // freshness timestamp. Another profile may have responded more recently.
    let requestedAt = Date(timeIntervalSince1970: 1000)
    let requestID = UUID().uuidString
    var inventoryA = snapshot([row(3, "https://anchor.example")])
    inventoryA.updatedAt = requestedAt.addingTimeInterval(0.1)
    inventoryA.profileDiscoveryRequestIDs = [requestID]
    let observedAt = requestedAt.addingTimeInterval(0.2)
    try expect(BrowserProfileSnapshots.isDiscoveryReply(inventoryA, owner: inventoryA, requestID: requestID,
        requestedAt: requestedAt, now: observedAt), "The exact owner's completed tab query proves its inventory")
    var inventoryB = inventoryA
    inventoryB.browserSessionID = "other-profile"; inventoryB.browserProfileID = profileB
    inventoryB.updatedAt = requestedAt.addingTimeInterval(0.15)
    try expect(!BrowserProfileSnapshots.isDiscoveryReply(inventoryB, owner: inventoryA, requestID: requestID,
        requestedAt: requestedAt, now: observedAt), "A fresher reply from another profile cannot prove absence or authorize a create")
    var ordinary = inventoryA; ordinary.profileDiscoveryRequestIDs = nil
    try expect(!BrowserProfileSnapshots.isDiscoveryReply(ordinary, owner: inventoryA, requestID: requestID,
        requestedAt: requestedAt, now: observedAt), "An ordinary heartbeat-refreshed inventory is not a discovery receipt")
    var prior = inventoryA; prior.profileDiscoveryRequestIDs = [UUID().uuidString]
    try expect(!BrowserProfileSnapshots.isDiscoveryReply(prior, owner: inventoryA, requestID: requestID,
        requestedAt: requestedAt, now: observedAt), "A prior discovery cannot be relabeled as this Run's inventory")
    var incomplete = inventoryA; incomplete.allTabs = nil
    try expect(!BrowserProfileSnapshots.isDiscoveryReply(incomplete, owner: inventoryA, requestID: requestID,
        requestedAt: requestedAt, now: observedAt), "Active-only tabs never certify that a saved tab is missing")
    try expect(!BrowserProfileSnapshots.isDiscoveryReply(inventoryA, owner: inventoryA, requestID: requestID,
        requestedAt: requestedAt, now: requestedAt.addingTimeInterval(4)), "Expired profile discovery cannot authorize later restoration")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("claims.json")
    let claims = SavedWorkspaceRestoreClaims(fileURL: file)
    _ = plan(duplicate, [snapshot([row(1), row(3, "https://anchor.example")])])
    try expect(!FileManager.default.fileExists(atPath: file.path), "Preparing or cancelling a saved workspace has no creation claim or browser effect")
    let requests = try claims.begin(sourceID: "preset-a", tabs: partial.pendingTabs)
    try expect(requests.count == 1 && UUID(uuidString: requests[0].requestID) != nil, "Explicit Run creates one durable request for each missing tab")
    let original = try Data(contentsOf: file)
    do { _ = try SavedWorkspaceRestoreClaims(fileURL: file).begin(sourceID: "preset-a", tabs: partial.pendingTabs)
        throw SpecFailure(description: "Restart/repeated Run must not reissue an uncertain browser create")
    } catch BrowserTabCreationError.uncertain { }
    let afterRepeatedRun = try Data(contentsOf: file)
    try expect(afterRepeatedRun == original, "Lost-receipt recovery preserves the original claim rather than replacing its UUID")
    let other = try claims.begin(sourceID: "preset-b", tabs: partial.pendingTabs)
    try expect(other.count == 1 && other[0].requestID != requests[0].requestID, "Separate explicit saved runs have separate effect identities")
    try claims.complete(sourceID: "preset-a")
    do { _ = try claims.begin(sourceID: "preset-b", tabs: partial.pendingTabs)
        throw SpecFailure(description: "Completing one preset must not retire another uncertain claim")
    } catch BrowserTabCreationError.uncertain { }
    _ = try claims.begin(sourceID: "preset-a", tabs: partial.pendingTabs)
    print("Saved workspace restoration specs passed")
}
