import AppKit
import IntentCore
import IntentLock
import SwiftUI

/// Opt-in checks against the actual app model, inside a disposable QA workspace.
/// No hotkeys, browser bridge, focus lock, credentials or daily data are started.
@MainActor
enum IntentPersistenceChecks {
    static func run() -> Int32 {
        guard IntentEnvironment.isQA else { return 2 }
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            if !value { throw NSError(domain: "IntentPersistenceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1
        }
        do {
            try QuickSelectionPreferenceChecks.run(check)
            try QuickSelectionInteractionChecks.run(check)
            try TabSiteIconChecks.run(check)
            let model = IntentAppModel()
            let presentation = SessionDismissalProbe()
            model.overlayPresenter = presentation
            model.dismissSessionPresentation()
            try check(presentation.events == ["hide-immediately", "hide-controls", "hide-expiry"],
                "Session completion dismisses every presentation without activation or a completion screen")
            presentation.events = []
            let completionID = UUID()
            model.completeSessionPresentation(occurrenceID: completionID, mode: .blacklist)
            try check(presentation.events == ["hide-immediately", "hide-controls", "hide-expiry", "complete-blacklist"],
                "Completion dismisses all controls before requesting nonactivating mode-aware feedback")
            try check(presentation.completionID == completionID, "Completion feedback carries its occurrence identity")
            let process = BrowserProcessIdentity(pid: 42, launched: 100)
            let visibilityRecord = BrowserWindowVisibilityRecord(browserBundleIdentifier: "com.google.Chrome",
                browserSessionID: "qa-profile", receivedAt: Date(timeIntervalSinceReferenceDate: 200),
                plan: .init(intentionSessionID: "qa-occurrence", revision: 1, windows: [
                    .init(windowID: 7, title: "QA", frame: .init(left: 0, top: 40, width: 800, height: 600), state: "normal")
                ]), browserProcessIdentity: process)
            var enforcement = BrowserWindowEnforcementPolicy(intentionSessionID: "qa-occurrence")
            let unresolved = BrowserWindowEnforcementPolicy.Observation(record: visibilityRecord, windowID: 7,
                liveProcessIdentity: process, outcome: .unresolved(.windowIdentityUnavailable))
            _ = enforcement.update([unresolved], activeIntentionSessionID: "qa-occurrence", now: 0)
            guard let failure = enforcement.update([unresolved], activeIntentionSessionID: "qa-occurrence", now: 3) else {
                throw NSError(domain: "IntentPersistenceChecks", code: 4)
            }
            presentation.events = []
            model.presentEnforcementFailure(occurrenceID: completionID, error: .browserWindowEnforcementFailed(failure))
            try check(presentation.events == ["hide-immediately", "hide-controls", "hide-expiry", "failure"],
                "Typed runtime failure dismisses old UI before its nonactivating notice, without showing the main overlay")
            try check(presentation.failureID == completionID && presentation.failureMessage == failure.message
                && model.errorMessage == failure.message, "Failure preserves exact details for explicit later opening")
            presentation.events = []
            model.presentEnforcementFailure(occurrenceID: completionID, error: .eventTapUnavailable)
            try check(presentation.events.isEmpty, "A generic startup error cannot produce the runtime restriction notice")
            model.activeSessionName = "Replacement"
            model.presentEnforcementFailure(occurrenceID: completionID, error: .browserWindowEnforcementFailed(failure))
            try check(presentation.events.isEmpty, "An old failure cannot replace UI after a new session starts")
            model.activeSessionName = nil; model.errorMessage = nil
            presentation.events = []
            model.emergencyStop()
            try check(!presentation.events.contains("show"), "Safety stop stores its reason without opening a new screen")
            model.overlayPresenter = nil
            // Enter the real asynchronous preflight using only isolated bridge
            // fixtures. Each task is canceled synchronously before its first
            // actor turn, so it must never enumerate the real desktop or construct a FocusLock.
            let coverageModel = IntentAppModel()
            let chrome = "com.google.Chrome", chromeSession = "qa-coverage-start"
            let oldAppearance = UserDefaults.standard.object(forKey: "distractionAppearance")
            UserDefaults.standard.set("hide", forKey: "distractionAppearance")
            defer {
                if let oldAppearance { UserDefaults.standard.set(oldAppearance, forKey: "distractionAppearance") }
                else { UserDefaults.standard.removeObject(forKey: "distractionAppearance") }
                coverageModel.cancelBrowserCoverageStart()
            }
            try BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: chrome)).write(
                capabilities: [BrowserGuardCapability.quickSelection, .tabSessionIdentity, .singleStartupLaunch, .nativeWindowVisibility].map(\.rawValue))
            try BrowserGuardStateStore(fileURL: BrowserGuardStateStore.fileURL(for: chrome)).write(enabled: true)
            let chromeSnapshot = BrowserTabSnapshot(browserBundleIdentifier: chrome, browserSessionID: chromeSession,
                tabs: [.init(id: 101, windowID: 201, index: 0, title: "QA", url: "https://example.test", active: true)])
            try JSONEncoder().encode(chromeSnapshot).write(to: BrowserTabSnapshotStore.fileURL(for: chrome), options: .atomic)
            var chromeSelection = QuickSelection()
            chromeSelection.toggleTab(.init(browser: chrome, id: 101), browserSessionID: chromeSession)
            let chromeApp = AllowedApp(name: "Chrome", bundleIdentifier: chrome)
            for cancel in [
                { coverageModel.endActiveSession() },
                { coverageModel.cancelFriction() },
                { coverageModel.cancelEndTimeSelection() },
                { coverageModel.cancelBrowserCoverageStart() },
                { coverageModel.showOverlay(animated: false) },
                { coverageModel.toggleOverlay() },
                { coverageModel.emergencyStop(showMessage: false) }
            ] {
                try check(coverageModel.startQuickSelection(chromeSelection, apps: [chromeApp], snapshots: [chromeSnapshot]),
                    "Selected Chrome tabs accept asynchronous coverage preparation")
                try check(coverageModel.isPreparingBrowserCoverage && !coverageModel.hasActiveSession,
                    "Chrome preparation does not claim a running intention before coverage")
                try check((try? JSONDecoder().decode(ActiveBrowserRules.self, from: Data(contentsOf: ActiveBrowserRulesStore.defaultFileURL())))?.active != true,
                    "No browser restriction is published while discovery is pending")
                cancel()
                try check(!coverageModel.isPreparingBrowserCoverage && !coverageModel.hasActiveSession,
                    "Finish/cancel/reopen prevents a delayed coverage reply from starting the old draft")
            }
            try check(coverageModel.startQuickSelection(chromeSelection, apps: [chromeApp], snapshots: [chromeSnapshot]),
                "Coverage can prepare again after cancellation")
            var replacement = try chromeSelection.makeIntention(apps: [chromeApp], snapshots: [chromeSnapshot])
            replacement.name = ""
            coverageModel.requestStart(replacement)
            try check(!coverageModel.isPreparingBrowserCoverage && !coverageModel.hasActiveSession,
                "Even a rejected replacement cancels the old asynchronous start")
            let app = AllowedApp(name: "Calculator", bundleIdentifier: "com.apple.calculator")
            var selection = QuickSelection(); selection.apps = [app.bundleIdentifier]
            let unnamed = try selection.makeIntention(apps: [app], snapshots: [])
            let workspace = SessionWorkspace(selection: selection, windows: [], tabs: [])
            var record = IntentSessionRecord(id: UUID(), intention: unnamed, workspace: workspace)
            record.endedAt = Date(); model.journal.upsert(record)
            let id = model.saveRecord(record)
            try check(id == unnamed.id && model.intentions.count == 1, "Unnamed run saves once with its stable ID")
            try check(model.savedIntentionID(for: record) == id, "Bookmark becomes filled")
            try check(model.saveRecord(record) == id && model.intentions.count == 1, "Repeated bookmark click cannot duplicate a setup")
            model.renameRecord(record.id, to: "  Check the numbers  ")
            try check(model.journal.records[0].intention.name == "Check the numbers" && !model.journal.records[0].intention.nameIsAutomatic, "Inline rename trims and changes history opacity metadata")
            try check(model.intentions[0].name == "Check the numbers", "Renaming saved history updates the slot")
            try check(model.journal.workspaces[id!]?.selection.name == "Check the numbers", "Saved workspace keeps the latest name")
            model.renameRecord(record.id, to: "")
            try check(model.intentions[0].name == "calculator" && model.intentions[0].nameIsAutomatic, "Clearing an explicit name restores its summary")
            selection.name = "Rename before saving"
            var second = IntentSessionRecord(id: UUID(), intention: try selection.makeIntention(apps: [app], snapshots: []), workspace: workspace)
            second.endedAt = Date(); model.journal.upsert(second)
            model.renameRecord(second.id, to: "Latest name")
            let secondID = model.saveRecord(second)
            try check(model.intentions.last?.name == "Latest name", "A stale row argument cannot overwrite an inline rename during save")
            try check(model.savedSlots.map(\.id) == [id!, secondID!], "New saves append to existing positions")
            model.moveSlot(id!, to: secondID!)
            try check(model.savedSlots.map(\.id) == [secondID!, id!], "Dragging swaps slot positions")
            let saved = try IntentionStore().load()
            let journalURL = model.profileDirectory.appendingPathComponent("session-journal.json")
            let loaded = try IntentSessionJournal.load(from: journalURL)
            try check(saved.count == 2 && loaded.slotOrder == [secondID!, id!], "Both saved setups and slot order survive reading from disk")
            try check(loaded.records.first?.savedIntentionID == id && loaded.workspaces.count == 2, "Bookmarks and exact replay workspaces survive disk persistence")
            model.activeSessionName = "Active"
            try check(model.saveRecord(second) == nil, "Saving is rejected while a session is running")
            let beforeName = model.intentions[0].name
            model.renameRecord(record.id, to: "Must not change")
            try check(model.intentions[0].name == beforeName, "Active sessions cannot mutate saved setups")
            model.activeSessionName = nil
            // Real disk failure: a directory cannot be atomically replaced by JSON.
            let journalData = try Data(contentsOf: journalURL)
            try FileManager.default.removeItem(at: journalURL)
            try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
            selection.name = "Failed save"
            let failed = IntentSessionRecord(id: UUID(), intention: try selection.makeIntention(apps: [app], snapshots: []), workspace: workspace)
            model.journal.upsert(failed)
            try check(model.saveRecord(failed) == nil && model.intentions.count == 2, "Journal failure rolls back the saved slot")
            let afterFailure = try IntentionStore().load()
            try check(afterFailure.count == 2, "Journal failure rolls back the intentions on disk too")
            model.renameRecord(record.id, to: "Failed rename")
            try check(model.intentions[0].name == beforeName && model.journal.records[0].intention.name == "calculator", "Rename failure preserves both history and slot name")
            try FileManager.default.removeItem(at: journalURL)
            try journalData.write(to: journalURL, options: .atomic)
            model.deleteIntention(id: secondID!)
            try check(model.savedSlots.map(\.id) == [id!], "Deleting a slot removes the gap and renumbers survivors")
            try check(model.savedIntentionID(for: second) == nil, "Deleting a saved setup clears its filled history bookmark")
            try check(model.journal.records.contains(where: { $0.id == second.id }), "Slot deletion preserves recent run history")
            model.undoLastChange()
            try check(model.savedSlots.map(\.id) == [secondID!, id!], "Undo restores the saved setup in its original position")
            let beforeDelete = model.intentions
            let intentionsURL = IntentionStore.defaultFileURL()
            let intentionsData = try Data(contentsOf: intentionsURL)
            try FileManager.default.removeItem(at: intentionsURL)
            try FileManager.default.createDirectory(at: intentionsURL, withIntermediateDirectories: true)
            model.deleteIntention(id: secondID!)
            try check(model.intentions == beforeDelete, "Failed deletion rolls back the visible slots")
            try FileManager.default.removeItem(at: intentionsURL)
            try intentionsData.write(to: intentionsURL, options: .atomic)
            let preparation = SpotlightAppPreparation.shared
            guard let calculatorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else {
                throw NSError(domain: "IntentPersistenceChecks", code: 2)
            }
            let beforePIDs = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).map(\.processIdentifier)
            let beforeFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var preparationFailure: String?
            preparation.prepare(calculatorURL) { preparationFailure = $0 }
            try check(preparationFailure == nil && preparation.staged.contains(app.bundleIdentifier), "A closed app can be staged without a background-launch warning")
            try check(NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).map(\.processIdentifier) == beforePIDs,
                "Staging never starts a process before the user runs the intention")
            try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == beforeFront, "Staging cannot steal foreground focus")
            preparation.release()
            try check(preparation.staged.isEmpty, "Removing an addition cancels its pending launch")
            preparation.prepare(calculatorURL) { preparationFailure = $0 }
            preparation.didStart()
            try check(preparation.staged.isEmpty, "Session start relinquishes staged additions")
            preparation.prepare(URL(fileURLWithPath: "/not-an-application")) { preparationFailure = $0 }
            try check(preparationFailure != nil && preparation.staged.isEmpty, "Unavailable applications are rejected rather than guessed")
            selection = QuickSelection(); selection.apps = [app.bundleIdentifier]; selection.startupAppIDs = [app.bundleIdentifier]
            let ready = try selection.makeIntention(apps: [app], snapshots: [])
            try check(IntentionStartupPlanner.steps(for: ready).contains(.openBundle(app.bundleIdentifier)), "Staged apps open when the intention starts")
            selection.accessMode = .blacklist
            let blocker = try selection.makeIntention(apps: [app], snapshots: [])
            try check(IntentionStartupPlanner.steps(for: blocker).isEmpty, "Saved blocker targets are never launched")
            // Render only our own mock views; this is not a live desktop acceptance check.
            let controller = QuickSelectionController(model: model)
            model.installedApps = [.init(name: app.name, bundleIdentifier: app.bundleIdentifier, url: calculatorURL,
                icon: NSWorkspace.shared.icon(forFile: calculatorURL.path))]
            controller.prepare(ready, workspace: workspace)
            try check(controller.selection.apps.contains(app.bundleIdentifier), "Saved closed apps remain selected on replay")
            try check((controller.selection.startupAppIDs ?? []).contains(app.bundleIdentifier), "Replay stages the closed app for Start")
            if beforePIDs.isEmpty {
                try check(controller.isAddedApplication(app.bundleIdentifier) && controller.windows.contains(where: { $0.appID == app.bundleIdentifier }),
                    "Saved closed app appears as a removable icon in the overview")
                var scoped = selection; scoped.accessMode = .whitelist
                scoped.windowIDsByApp = [app.bundleIdentifier: [12345]]
                let scopedWorkspace = SessionWorkspace(selection: scoped, windows: [.init(app: app.bundleIdentifier, title: "Previous calculator")], tabs: [])
                controller.prepare(ready, workspace: scopedWorkspace)
                try check(controller.selection.apps.contains(app.bundleIdentifier) && controller.selection.windowIDsByApp[app.bundleIdentifier] == nil,
                    "An entirely closed native app can reopen its default window without permitting unrelated existing windows")
                controller.removeAddedApplication(app.bundleIdentifier)
                try check(!controller.selection.apps.contains(app.bundleIdentifier) && !controller.isAddedApplication(app.bundleIdentifier)
                    && !controller.windows.contains(where: { $0.appID == app.bundleIdentifier }), "App X clears its target, placeholder and staged launch")
                try check(NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty, "Removing a staged app never opens it")
                controller.prepare(blocker, workspace: nil)
                try check(controller.selection.accessMode == .blacklist && controller.selection.apps.contains(app.bundleIdentifier),
                    "Populated saved blacklist slots restore their target and mode")
                try check(IntentionStartupPlanner.steps(for: try controller.selection.makeIntention(apps: [app], snapshots: [])).isEmpty,
                    "A replayed blacklist never opens the blocked app")
            }
            preparation.release()
            let preview = VStack(spacing: 20) {
                IntentOptionalNameBar(name: .constant("")).frame(width: 520)
                IntentSavedSlotsView(controller: controller, model: model)
                IntentSessionNotesView(controller: controller, model: model).frame(width: 260, height: 250)
            }.padding(32).frame(width: 1100, height: 600).background(Color(red: 0.12, green: 0.33, blue: 0.4))
                .foregroundStyle(.white).preferredColorScheme(.dark).coordinateSpace(name: "IntentOverview")
            let host = NSHostingView(rootView: preview); host.frame = .init(x: 0, y: 0, width: 1100, height: 600)
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: IntentEnvironment.dataDirectory.appendingPathComponent("naming-slots-preview.png"))
                }
            }
            print("Intent app persistence checks passed (\(checks) assertions; isolated model, no live UI claim).")
            return 0
        } catch {
            fputs("Intent app persistence checks failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

@MainActor
private final class SessionDismissalProbe: IntentOverlayPresenting {
    var events: [String] = []
    var completionID: UUID?
    var failureID: UUID?
    var failureMessage: String?
    var isOverlayVisible: Bool { true }
    var isSessionControlsExpanded: Bool { true }
    func showOverlay(animated: Bool) { events.append("show") }
    func hideOverlay(animated: Bool) { events.append(animated ? "hide-animated" : "hide-immediately") }
    func toggleOverlay() { events.append("toggle") }
    func prepareSessionPresentation(occurrenceID: UUID) { events.append("prepare") }
    func showSessionControls(occurrenceID: UUID) { events.append("show-controls") }
    func collapseSessionControlsIfExpanded() -> Bool { false }
    func toggleSessionControls() { events.append("toggle-controls") }
    func toggleSessionControlsExpansion() {}
    func hideSessionTimer() { events.append("hide-controls") }
    func hideSessionExpiry() { events.append("hide-expiry") }
    func showSessionCompletion(occurrenceID: UUID, mode: IntentionAccessMode) {
        completionID = occurrenceID; events.append("complete-\(mode.rawValue)")
    }
    func showSessionFailure(occurrenceID: UUID, message: String) {
        failureID = occurrenceID; failureMessage = message; events.append("failure")
    }
}
