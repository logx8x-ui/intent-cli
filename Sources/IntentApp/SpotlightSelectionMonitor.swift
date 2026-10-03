import AppKit
import ApplicationServices
import IntentCore

/// Observes Apple's real Spotlight. Query text is never used to guess an app.
final class SpotlightSelectionMonitor {
    var onApplication: ((URL) -> Void)?
    var onVisibility: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    private let queue = DispatchQueue(label: "intent.spotlight-selection", qos: .userInitiated)
    private let mutex = NSLock()
    private var timer: DispatchSourceTimer?
    private var isSpotlight = false
    private var armed = false
    private var observedAt = Date.distantPast
    private var field: AXUIElement?
    private var enterPending = false
    private var spotlightOpeningUntil = Date.distantPast
    private var revision = 0
    private var overview = false
    private var candidates: [SpotlightApplicationCandidate] = []

    func setOverview(active: Bool, candidates: [SpotlightApplicationCandidate]) {
        mutex.lock(); defer { mutex.unlock() }
        if overview != active { revision += 1 }
        overview = active; self.candidates = candidates
    }
    func cancelSelection() {
        mutex.lock(); revision += 1; overview = false; armed = false; mutex.unlock()
    }
    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.08)
        timer.setEventHandler { [weak self] in self?.scan() }
        self.timer = timer; timer.resume()
    }
    /// Cached state only: the input tap never blocks on an AX message.
    func handle(code: Int, down: Bool, modified: Bool, openingShortcut: Bool, repeatKey: Bool) -> Bool? {
        mutex.lock()
        if openingShortcut && down { spotlightOpeningUntil = Date(timeIntervalSinceNow: 1.5) }
        let opening = Date() < spotlightOpeningUntil
        guard (isSpotlight && Date().timeIntervalSince(observedAt) < 0.5) || opening else {
            mutex.unlock(); return nil
        }
        if down { revision += 1 }
        if code == 53 { armed = false }
        if code == 50 && down && !modified { armed = true }
        let submit = [36, 76].contains(code) && !modified && (armed || overview)
        let resolve = submit && down && !repeatKey && !enterPending
        if resolve { enterPending = true }
        mutex.unlock()
        if resolve { queue.async { [weak self] in self?.submit() } }
        return submit
    }
    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        // A system-wide focus query can synchronously serialize our own SwiftUI
        // field editor on this worker queue. Never inspect system-wide or
        // in-process elements here: Spotlight is always an external process.
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.06)
        var output: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &output) == .success else { return nil }
        return output
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func windows(_ app: AXUIElement) -> [AXUIElement] {
        if let focused = element(value(app, kAXFocusedWindowAttribute)) { return [focused] }
        let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if !windows.isEmpty { return windows }
        // Newer Spotlight exposes its search surface as an AXSystemDialog,
        // an application child rather than an AXWindow.
        return (value(app, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
            let role = value($0, kAXRoleAttribute) as? String ?? ""
            return role != kAXMenuBarRole && role != kAXButtonRole
        }
    }
    private func belongsToSpotlight(_ item: AXUIElement) -> Bool {
        var pid: pid_t = 0; AXUIElementGetPid(item, &pid)
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.Spotlight"
    }
    private func searchField(in roots: [AXUIElement]) -> AXUIElement? {
        var pending = roots; var visited = Set<CFHashCode>()
        let deadline = Date(timeIntervalSinceNow: 0.15)
        while !pending.isEmpty, visited.count < 120, Date() < deadline {
            let item = pending.removeFirst()
            guard visited.insert(CFHash(item)).inserted else { continue }
            let role = value(item, kAXRoleAttribute) as? String ?? ""
            if [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"].contains(role), value(item, kAXValueAttribute) is String { return item }
            pending += value(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return nil
    }
    private func focusedField() -> AXUIElement? {
        // Spotlight is a system panel: AX focus can remain on its previous app.
        // Require an on-screen surface, including nonzero-layer system panels.
        // A retained AX focused field after dismissal must not intercept Return.
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Spotlight")
        guard !apps.isEmpty else { return nil }
        let visibleWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visiblePIDs = Set(visibleWindows.compactMap { info -> pid_t? in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 40, frame.height > 40,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return pid
        })
        for app in apps where visiblePIDs.contains(app.processIdentifier) {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            if let focused = element(value(application, kAXFocusedUIElementAttribute)), belongsToSpotlight(focused) {
                let role = value(focused, kAXRoleAttribute) as? String ?? ""
                if [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"].contains(role) { return focused }
            }
            let roots = windows(application)
            if let search = searchField(in: roots) { return search }
        }
        return nil
    }
    private func diagnostic(_ event: String) {
        let status: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "event": event,
            "updatedAt": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
            try? data.write(to: IntentEnvironment.dataDirectory.appendingPathComponent("spotlight-status.json"), options: .atomic)
        }
    }
    private func scan() {
        mutex.lock(); let submitting = enterPending; mutex.unlock()
        guard !submitting else { return }
        let current = focusedField()
        let raw = current.flatMap { value($0, kAXValueAttribute) as? String }
        mutex.lock()
        let changed = isSpotlight != (current != nil)
        isSpotlight = current != nil; observedAt = Date(); field = current
        armed = raw.flatMap(SpotlightSelectionPolicy.markedQuery) != nil
        mutex.unlock()
        if changed { diagnostic(current == nil ? "closed" : "native-search-ready"); DispatchQueue.main.async { [weak self] in self?.onVisibility?(current != nil) } }
    }
    private func selectedURL(in roots: [AXUIElement], catalog: [SpotlightApplicationCandidate]) -> URL? {
        var pending = roots.map { ($0, false, false) }
        var visited = Set<CFHashCode>(); var urls = Set<URL>()
        var names = Set<String>()
        let deadline = Date(timeIntervalSinceNow: 0.3)
        while !pending.isEmpty, visited.count < 240, Date() < deadline {
            let (item, selectedAncestor, applicationAncestor) = pending.removeFirst()
            guard visited.insert(CFHash(item)).inserted else { continue }
            let role = value(item, kAXRoleAttribute) as? String ?? ""
            if [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField", kAXButtonRole, kAXMenuBarRole].contains(role) { continue }
            let selected = selectedAncestor || value(item, kAXSelectedAttribute) as? Bool == true
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { value(item, $0) as? String }
            let metadata = [kAXDescriptionAttribute, kAXIdentifierAttribute].compactMap { value(item, $0) as? String }
            let application = applicationAncestor || metadata.contains(where: SpotlightSelectionPolicy.isApplicationResult)
                || labels.contains { ["application", "applications", "app", "apps"].contains($0.lowercased()) }
            if selected {
                for attr in [kAXURLAttribute, kAXDocumentAttribute, "AXFilename", kAXValueAttribute] {
                    if let raw = value(item, attr), let url = SpotlightSelectionPolicy.applicationURL(String(describing: raw)) { urls.insert(url) }
                }
                if application { names.formUnion(labels) }
            }
            let selectedChildren = (value(item, kAXSelectedChildrenAttribute) as? [AXUIElement] ?? []) + (value(item, kAXSelectedRowsAttribute) as? [AXUIElement] ?? [])
            pending.insert(contentsOf: selectedChildren.map { ($0, true, application) }, at: 0)
            let children = (value(item, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { ($0, selected, application) }
            // Read the selected result's label before walking all the unrelated
            // document/web results. A large result list must not exhaust the AX
            // time budget before reaching the application's own text child.
            if selected { pending.insert(contentsOf: children, at: 0) }
            else { pending += children }
        }
        if urls.count == 1 { return urls.first }
        guard urls.isEmpty else { return nil }
        let matches = Set(names.compactMap { SpotlightSelectionPolicy.selectedApplication(named: $0, isApplication: true, candidates: catalog) })
        return matches.count == 1 ? matches.first : nil
    }
    private func submit() {
        defer { mutex.lock(); enterPending = false; mutex.unlock() }
        mutex.lock(); let expectedRevision = revision; let inOverview = overview; let catalog = candidates; mutex.unlock()
        diagnostic("return-intercepted")
        guard let search = focusedField(), let raw = value(search, kAXValueAttribute) as? String else { fail(); return }
        let marked = SpotlightSelectionPolicy.markedQuery(raw)
        guard inOverview || marked != nil, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail(); return }
        let expected = marked ?? raw
        if marked != nil {
            guard AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, expected as CFString) == .success else { fail(); return }
        }
        var pid: pid_t = 0; AXUIElementGetPid(search, &pid)
        let app = AXUIElementCreateApplication(pid)
        let deadline = Date(timeIntervalSinceNow: marked == nil ? 0.6 : 1.2)
        var resolved: URL?
        repeat {
            mutex.lock(); let valid = revision == expectedRevision && (!inOverview || overview); mutex.unlock()
            guard valid else { return }
            guard value(search, kAXValueAttribute) as? String == expected else { return }
            resolved = selectedURL(in: windows(app), catalog: catalog)
            if resolved != nil { break }
            Thread.sleep(forTimeInterval: 0.06)
        } while Date() < deadline
        guard let url = resolved, Bundle(url: url)?.bundleIdentifier != nil else { fail(); return }
        mutex.lock(); let valid = revision == expectedRevision; mutex.unlock()
        guard valid else { return }
        // Send Escape only to the native panel, never press its result or launch
        // the chosen app in front of the user's unfinished selection.
        NativeSpotlightKeyboard.dismiss(pid: pid)
        mutex.lock(); armed = false; isSpotlight = false; field = nil; mutex.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mutex.lock(); let stillValid = self.revision == expectedRevision; self.mutex.unlock()
            if stillValid { self.diagnostic("application-added"); self.onApplication?(url) }
        }
    }
    private func fail() {
        diagnostic("selected-application-unavailable")
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?("Choose an application result in Apple Spotlight, then press Return. Intent could not identify the selected application.")
        }
    }
    deinit { timer?.cancel() }
}
