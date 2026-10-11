import AppKit
import IntentCore

/// Production controller checks with no ordered windows, input or focus session.
@MainActor
enum QuickSelectionInteractionChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        try WebsiteFinderFocusChecks.run(check)
        try OptionalNameDismissalChecks.run(check)
        try OverviewAddedAppIconChecks.run(check)
        try checkSpotlightMarks(check)
        let modifierPanel = QuickSelectionController.makeStagedModifierPanel(frame: .init(x: 0, y: 0, width: 500, height: 70))
        try check(modifierPanel.styleMask.contains(.nonactivatingPanel) && modifierPanel.canBecomeKey && !modifierPanel.canBecomeMain,
            "The real staged editor panel accepts keyboard focus without becoming an activating main window")
        modifierPanel.close()
        let controller = QuickSelectionController(model: IntentAppModel())
        try check(controller.includesWebsiteAdder == IntentBuildPolicy.current.includesWebsiteAdder,
            "The production overview uses the compiled feature policy, not a persisted user preference")
        if !controller.includesWebsiteAdder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let before = try encoder.encode(controller.selection)
            controller.message = "Existing draft"
            controller.openWebsiteFinder()
            let after = try encoder.encode(controller.selection)
            try check(controller.currentWebsiteFinderTarget == nil && controller.nativeWebsiteFinder == nil
                && controller.websiteFinder == nil && !controller.creatingWebsiteTab
                && after == before && controller.message == "Existing draft",
                "The launch controller refuses a direct website-adder action without altering a draft or starting browser work")
            controller.message = nil
        }
        var canceledController: QuickSelectionController?
        canceledController = QuickSelectionController(model: IntentAppModel(), offerExitPasscode: {
            canceledController?.cancelImmediately()
        })
        canceledController?.openModification(.timer)
        try check(canceledController?.optionsSection == nil
            && canceledController?.selection.restrictionNodes.isEmpty == true
            && canceledController?.isSelectionSurfaceVisible == false,
            "Cancel during the first-use modifier prompt cannot enable a timer or recreate its controls")
        canceledController = nil
        // Exercise the actual overview-cancel owner without ordering desktop
        // panels in model QA. Cancellation must not revive the DBT draft.
        let transitions = QuickSelectionController(model: IntentAppModel())
        for _ in 0..<3 {
            transitions.selection.toggleWindow(501, app: "qa.retained")
            QuickSelectionOptionsSection.stopwatch.enable(in: &transitions.selection)
            transitions.cancelImmediately()
            try check(transitions.selection.apps.isEmpty && transitions.selection.restrictionNodes.isEmpty
                && transitions.selection.frictionNodes.isEmpty && !transitions.isStagedModifierSurfaceVisible,
                "Leaving overview clears targets and modifiers without restoring staged presentation")
        }
        transitions.selection.toggleTab(.init(browser: "org.mozilla.firefox", id: 31), browserSessionID: "qa-picker")
        QuickSelectionOptionsSection.checklist.enable(in: &transitions.selection)
        transitions.selection.name = "Discard this draft"
        transitions.prepareOverviewEntry()
        try check(transitions.selection.apps.isEmpty && transitions.selection.tabs.isEmpty
            && transitions.selection.frictionNodes.isEmpty && transitions.selection.name.isEmpty,
            "DBT to SBT begins a fresh overview without old tabs, name or checklist")
        transitions.clearMarks(); transitions.cancelImmediately()
        try check(!transitions.isStagedModifierSurfaceVisible, "Cleared targets cannot resurrect a staged strip")
        var saved = Intention(id: "qa-explicit-overview", name: "Saved setup", icon: "timer", colorHex: "#34C759", folder: "",
            allowedApps: [], allowedWebsites: [], startupActions: [], restrictions: .init())
        saved.restrictionNodes = [.init(kind: .timer, position: .zero, durationMinutes: 7)]
        saved.frictionNodes = [.init(friction: .taskChecklist(["Saved line"]), position: .zero)]
        transitions.prepare(saved, workspace: nil)
        transitions.prepareOverviewEntry()
        try check(transitions.selection.name == "Saved setup"
            && transitions.selection.restrictionNodes.first?.durationMinutes == 7
            && transitions.selection.frictionNodes == saved.frictionNodes,
            "Explicit saved-intention entry retains its own timer and checklist")
        transitions.prepareOverviewEntry()
        try check(transitions.selection.restrictionNodes.isEmpty && transitions.selection.frictionNodes.isEmpty,
            "Saved preloading is consumed once, never carried into a later fresh overview")
        QuickSelectionOptionsSection.checklist.enable(in: &transitions.selection)
        transitions.optionsSection = .checklist
        transitions.closeModification()
        try check(!QuickSelectionOptionsSection.checklist.enabled(in: transitions.selection),
            "The real controller removes a blank checklist when its editor dismisses")
        transitions.selection.frictionNodes = saved.frictionNodes
        transitions.optionsSection = .checklist
        transitions.closeModification()
        try check(transitions.selection.frictionNodes == saved.frictionNodes,
            "The real controller retains written checklist lines after editor dismissal")
        // These switches require no editor, target, browser IPC or Keychain UI.
        // Their keyboard entry point must work without an optional name.
        controller.modificationOrder = [.addAsYouGo, .stopwatch]
        for (index, section) in controller.modificationOrder.enumerated() {
            controller.openModification(index)
            try check(controller.selection.name.isEmpty && section.enabled(in: controller.selection),
                "Numbered \(section.rawValue) enables on an unnamed draft through the real controller")
            controller.openModification(index)
            try check(!section.enabled(in: controller.selection),
                "The same numbered modification disables on its next press")
        }
        let before = controller.selection.restrictionNodes
        controller.openModification(-1); controller.openModification(6)
        try check(controller.selection.restrictionNodes == before, "Invalid modification indices leave the draft untouched")

        let browser = "org.mozilla.firefox"
        var retainedOverview = QuickSelection()
        retainedOverview.toggleWindow(501, app: "qa.retained")
        retainedOverview.startupAppIDs = ["qa.retained"]
        let currentSession = QuickSelectionController.markedRunSelection(retainedOverview)
        let currentIntention = try currentSession.makeIntention(apps: [.init(name: "QA retained", bundleIdentifier: "qa.retained")], snapshots: [])
        try check(currentSession.startupAppIDs == [] && currentIntention.dontStartResourceIDs.contains("app:qa.retained")
            && retainedOverview.startupAppIDs == ["qa.retained"],
            "Overview to DBT suppresses startup only for this Run, preserving the retained draft's launch policy")
        let tab = BrowserTabItem(id: 31, windowID: 41, index: 0, title: "QA selected", url: "https://example.test", active: true)
        let native = QuickSelectionController.WindowItem(id: 51, appID: "qa.native", title: "QA native",
            sourceFrame: .init(x: 0, y: 0, width: 800, height: 600), preview: nil)
        controller.selection.toggleTab(.init(browser: browser, id: tab.id), browserSessionID: "qa-picker")
        func seedPicker() {
            controller.focusedBrowserWindow = 61
            controller.explicitBrowserWindow = .init(browser: browser, id: tab.windowID)
            controller.hoveredTab = tab
            controller.tabPreview = NSImage(size: .init(width: 1, height: 1))
            controller.tabPreviewError = "old preview"
            controller.tabPreviewLoading = true
        }
        func isDismissed() -> Bool {
            controller.focusedBrowserWindow == nil && controller.explicitBrowserWindow == nil
                && controller.hoveredTab == nil && controller.tabPreview == nil
                && controller.tabPreviewError == nil && !controller.tabPreviewLoading
                && !controller.resolvingBrowserWindow
        }
        seedPicker()
        controller.selectWindow(native)
        try check(isDismissed(), "Selecting a non-browser window dismisses all browser picker and preview state")
        try check(controller.selection.windowIDsByApp[native.appID] == [native.id]
            && controller.selection.tabs == [.init(browser: browser, id: tab.id)],
            "Picker dismissal selects the native window without losing previously chosen browser tabs")
        seedPicker()
        controller.selectApp(.init(app: .init(name: "QA native", bundleIdentifier: "qa.app"),
            icon: NSImage(size: .init(width: 1, height: 1)), pid: 0))
        try check(isDismissed() && controller.selection.apps.contains("qa.app"),
            "Windowless native app selection also dismisses the browser picker")
        seedPicker(); controller.toggleSlots()
        try check(isDismissed(), "Showing saved slots cannot leave a stale browser preview behind")
        seedPicker(); controller.dismissBrowserPicker(); controller.dismissBrowserPicker()
        try check(isDismissed() && controller.selection.tabs.count == 1,
            "Closing a browser picker is idempotent and does not deselect its tabs")
        let browserWindow = QuickSelectionController.WindowItem(id: 61, appID: browser, title: tab.title,
            sourceFrame: native.sourceFrame, preview: nil)
        controller.windows = [browserWindow, native]
        controller.snapshots = [.init(browserBundleIdentifier: browser, browserSessionID: "qa-picker", tabs: [tab])]
        let sibling = QuickSelectionController.WindowItem(id: 62, appID: browser, title: "Other browser window",
            sourceFrame: .init(x: 900, y: 0, width: 700, height: 600), preview: nil)
        let unselectedTab = BrowserTabItem(id: 32, windowID: 41, index: 1, title: "Unselected", url: "https://second.test", active: false)
        let otherTab = BrowserTabItem(id: 33, windowID: 42, index: 0, title: sibling.title, url: "https://third.test", active: true)
        let anchorSnapshot = BrowserTabSnapshot(browserBundleIdentifier: browser, browserSessionID: "qa-picker", tabs: [tab, unselectedTab, otherTab])
        let anchor = QuickSelectionController.markedRunAnchor(windowID: 61, pid: 700, bundle: browser,
            title: tab.title, frame: native.sourceFrame, nativeWindowCount: 2, snapshot: anchorSnapshot)
        try check(anchor?.nativeWindowID == 61 && anchor?.browserWindowID == 41 && anchor?.browserTabID == 31,
            "DBT submission pins the current native window and active tab, not the first other allowed window")
        try check(QuickSelectionController.markedRunAnchor(windowID: 61, pid: 700, bundle: browser,
            title: tab.title, frame: native.sourceFrame, nativeWindowCount: 2, snapshot: nil) == nil,
            "An unresolved browser start cannot substitute a guessed tab or app fallback")
        try check(QuickSelectionController.markedRunAnchor(windowID: 51, pid: 800, bundle: "qa.native",
            title: "QA", frame: native.sourceFrame, nativeWindowCount: 1, snapshot: nil)?.nativeWindowID == 51,
            "Native DBT starts need no browser metadata or navigation")
        controller.windows = [browserWindow, sibling, native]
        controller.snapshots = [.init(browserBundleIdentifier: browser, browserSessionID: "qa-picker", tabs: [tab, unselectedTab, otherTab])]
        try check(controller.isSelected(browserWindow) && !controller.isSelected(sibling),
            "One selected tab marks its exact browser window, not another window or only fully selected windows")
        controller.snapshots = [.init(browserBundleIdentifier: browser, browserSessionID: "replacement-session", tabs: [tab, unselectedTab, otherTab])]
        try check(!controller.isSelected(browserWindow), "Reused tab IDs from a new browser session cannot inherit a window highlight")
        controller.snapshots = [.init(browserBundleIdentifier: browser, browserSessionID: "qa-picker", tabs: [tab])]
        controller.windows = [browserWindow, native]
        controller.selectWindow(browserWindow) // queues the actual resolution task
        controller.selectWindow(native) // dismisses before its first actor turn
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        try check(isDismissed() && controller.selection.tabs.count == 1,
            "A canceled pending browser resolution cannot reenter loading or revive picker state after a native click")
    }
    private static func checkSpotlightMarks(_ check: (Bool, String) throws -> Void) throws {
        for mode in IntentionAccessMode.allCases {
            for id in ["qa.spotlight.native", "org.mozilla.firefox", "com.google.Chrome"] {
                let controller = QuickSelectionController(model: IntentAppModel())
                controller.selection.accessMode = mode
                controller.selection.windowIDsByApp[id] = [41]
                let app = AllowedApp(name: "QA Spotlight", bundleIdentifier: id)
                controller.apps = [.init(app: app, icon: NSImage(size: CGSize(width: 128, height: 128)), pid: 0)]
                let oldInventory = controller.windows
                controller.stageSpotlightApplication(app, alreadyRunning: false)
                controller.windows = controller.preserveAddedAppIcons(in: oldInventory)
                guard let icon = controller.windows.first(where: { $0.appID == id }) else {
                    throw NSError(domain: "SpotlightMarkChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Spotlight did not preserve its icon"])
                }
                try check(controller.isAddedApplicationIcon(icon) && controller.isSelected(icon)
                    && controller.selection.apps.contains(id) && controller.selection.windowIDsByApp[id] == nil,
                    "Native and browser Spotlight additions are selected before icon preparation returns")
                try check(controller.canRemoveAddedApplication(id),
                    "A genuinely new Spotlight addition keeps its removal control")
                controller.stageSpotlightApplication(app, alreadyRunning: true)
                try check(controller.canRemoveAddedApplication(id),
                    "A later process inventory cannot turn a staged addition into an existing-app selection")
                try check(controller.selection.marksNativeWindow(42, app: id),
                    "A whole-app Spotlight selection also authorizes its native selection outline")
                try check((controller.selection.startupAppIDs?.contains(id) == true) == (mode == .whitelist),
                    "Allow additions stage startup; block additions never stage launching")
                controller.windows = controller.preserveAddedAppIcons(in: oldInventory)
                try check(controller.windows.count == 1 && controller.isSelected(controller.windows[0]),
                    "An older async preview inventory cannot erase or unselect the Spotlight icon")
                controller.selectWindow(icon)
                controller.windows = controller.preserveAddedAppIcons(in: oldInventory)
                try check(controller.windows.count == 1 && !controller.isSelected(controller.windows[0])
                    && !controller.selection.marksNativeWindow(42, app: id),
                    "Deselecting an added icon removes its outline while keeping it available for reselection")
                controller.selectWindow(icon)
                try check(controller.isSelected(icon)
                    && (controller.selection.startupAppIDs?.contains(id) == true) == (mode == .whitelist),
                    "A second icon click reselects native apps and browsers without tab-identity errors or premature launching")
                controller.removeAddedApplication(id)
                controller.windows = controller.preserveAddedAppIcons(in: oldInventory)
                try check(controller.windows.isEmpty && !controller.selection.marksNativeWindow(42, app: id),
                    "Removing the selection prevents a late preview inventory from reviving its icon or border")
                try check(!controller.canRemoveAddedApplication(id),
                    "Removing an addition retires its removal ownership")

                // Removal refreshes the live inventory. Restore the synthetic
                // app before exercising the independent existing-app case.
                controller.apps = [.init(app: app, icon: NSImage(size: CGSize(width: 128, height: 128)), pid: 0)]
                controller.stageSpotlightApplication(app, alreadyRunning: true)
                let existingWindow = QuickSelectionController.WindowItem(id: 42, appID: id, title: "Existing app",
                    sourceFrame: .init(x: 0, y: 0, width: 800, height: 600), preview: nil)
                controller.windows = [existingWindow]
                try check(controller.isSelected(existingWindow) && !controller.canRemoveAddedApplication(id),
                    "Spotlight highlights an existing app without offering window removal in either mode")
                let existingSelection = controller.selection
                controller.removeAddedApplication(id)
                try check(controller.selection.apps == existingSelection.apps
                    && controller.selection.tabs == existingSelection.tabs
                    && controller.selection.windowIDsByApp == existingSelection.windowIDsByApp
                    && controller.selection.wholeBrowserApps == existingSelection.wholeBrowserApps
                    && controller.selection.startupAppIDs == existingSelection.startupAppIDs
                    && controller.selection.accessMode == existingSelection.accessMode
                    && controller.windows.map(\.id) == [42],
                    "A stale removal action cannot deselect or remove an existing app")
                controller.windows = controller.preserveAddedAppIcons(in: [])
                guard let existingIcon = controller.windows.first else {
                    throw NSError(domain: "SpotlightMarkChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Existing app icon missing"])
                }
                try check(controller.isAddedApplicationIcon(existingIcon) && controller.isSelected(existingIcon)
                    && !controller.canRemoveAddedApplication(id),
                    "An already-running windowless app can use an icon without receiving an X")
                controller.selectWindow(existingIcon); controller.selectWindow(existingIcon)
                controller.stageSpotlightApplication(app, alreadyRunning: false)
                controller.windows = controller.preserveAddedAppIcons(in: [])
                try check(controller.isSelected(controller.windows[0]) && !controller.canRemoveAddedApplication(id),
                    "Reselection, repeated search and late missing-process inventory preserve existing-app origin")
                controller.clearMarks()
                controller.stageSpotlightApplication(app, alreadyRunning: false)
                try check(controller.canRemoveAddedApplication(id),
                    "A new draft reclassifies the app instead of retaining previous existing-app origin")
                controller.clearMarks()
            }
        }
        var tabs = QuickSelection()
        tabs.toggleTab(.init(browser: "org.mozilla.firefox", id: 7), browserSessionID: "qa-outline")
        try check(!tabs.marksNativeWindow(42, app: "org.mozilla.firefox"),
            "Selecting one browser tab never becomes a whole-app outline")
        tabs.toggleWindow(42, app: "qa.exact.window")
        try check(tabs.marksNativeWindow(42, app: "qa.exact.window") && !tabs.marksNativeWindow(43, app: "qa.exact.window"),
            "Exact native selections never outline an unselected sibling")
    }
}
