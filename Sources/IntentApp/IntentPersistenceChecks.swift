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
            let model = IntentAppModel()
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
