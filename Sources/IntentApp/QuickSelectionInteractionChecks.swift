import AppKit
import IntentCore

/// Production controller checks with no ordered windows, input or focus session.
@MainActor
enum QuickSelectionInteractionChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
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
        controller.selectWindow(browserWindow) // queues the actual resolution task
        controller.selectWindow(native) // dismisses before its first actor turn
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        try check(isDismissed() && controller.selection.tabs.count == 1,
            "A canceled pending browser resolution cannot reenter loading or revive picker state after a native click")
    }
}
