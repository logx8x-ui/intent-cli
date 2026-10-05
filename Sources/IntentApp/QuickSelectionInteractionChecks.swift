import AppKit
import IntentCore

/// Production controller checks with no ordered windows, input or focus session.
@MainActor
enum QuickSelectionInteractionChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        let modifierPanel = QuickSelectionController.makeStagedModifierPanel(frame: .init(x: 0, y: 0, width: 500, height: 46))
        try check(modifierPanel.styleMask.contains(.nonactivatingPanel) && modifierPanel.canBecomeKey && !modifierPanel.canBecomeMain,
            "The real staged editor panel accepts keyboard focus without becoming an activating main window")
        modifierPanel.close()
        let controller = QuickSelectionController(model: IntentAppModel())
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
        // panels in model QA. The injected presenter receives the retained draft.
        var returnedDrafts: [QuickSelection] = []
        let transitions = QuickSelectionController(model: IntentAppModel(),
            presentStagedSelection: { returnedDrafts.append($0) })
        transitions.selection.toggleWindow(501, app: "qa.retained")
        QuickSelectionOptionsSection.stopwatch.enable(in: &transitions.selection)
        for _ in 0..<3 {
            transitions.cancelImmediately()
            try check(returnedDrafts.last?.windowIDsByApp["qa.retained"] == [501]
                && returnedDrafts.last.map { QuickSelectionOptionsSection.stopwatch.enabled(in: $0) } == true,
                "Leaving overview requests staged presentation with the retained modifiers and targets")
        }
        try check(returnedDrafts.count == 3, "Repeated overview/escape cycles each restore staged presentation")
        transitions.clearMarks(); transitions.cancelImmediately()
        try check(returnedDrafts.count == 3, "Cleared targets cannot resurrect a staged strip")
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
}
