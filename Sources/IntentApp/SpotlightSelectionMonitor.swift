import AppKit
import ApplicationServices
import IntentCore

/// Polls only Spotlight's focused accessibility surface. No result is inferred
/// from its title or the query; Return requires one selected application URL.
final class SpotlightSelectionMonitor {
    var onApplication: ((URL) -> Void)?
    var onFailure: ((String) -> Void)?
    private let queue = DispatchQueue(label: "intent.spotlight-selection", qos: .userInitiated)
    private let mutex = NSLock()
    private var timer: DispatchSourceTimer?
    private var isSpotlight = false
    private var armed = false
    private var observedAt = Date.distantPast
    private var field: AXUIElement?
    private var cleanQuery = ""
    private var invalid = false
    private var enterPending = false
    private var spotlightOpeningUntil = Date.distantPast
    private var revision = 0
    private var lastKeyAt = Date.distantPast

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.08)
        timer.setEventHandler { [weak self] in self?.scan() }
        self.timer = timer; timer.resume()
    }

    /// Called by the keyboard tap; cached state only, never AX or file work.
    /// nil = normal Intent gesture path, false = pass through to Spotlight,
    /// true = consume a marked submission until its exact result is resolved.
    func handle(code: Int, down: Bool, modified: Bool, openingShortcut: Bool, repeatKey: Bool) -> Bool? {
        mutex.lock()
        if openingShortcut && down { spotlightOpeningUntil = Date(timeIntervalSinceNow: 0.5) }
        guard isSpotlight && Date().timeIntervalSince(observedAt) < 0.4 else {
            let opening = Date() < spotlightOpeningUntil
            mutex.unlock(); return opening ? false : nil
        }
        if down { revision += 1; lastKeyAt = Date() }
        if code == 53 { armed = false; invalid = false }
        if code == 50 && down && !modified { armed = true }
        let submit = [36, 76].contains(code) && !modified && armed
        let shouldResolve = submit && down && !repeatKey && !enterPending
        if shouldResolve { enterPending = true }
        mutex.unlock()
        if shouldResolve { queue.async { [weak self] in self?.submit() } }
        return submit
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.035)
        var output: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &output) == .success else { return nil }
        return output
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func focusedField() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        guard let focused = element(value(system, kAXFocusedUIElementAttribute)) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.Spotlight" else { return nil }
        if [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"].contains(value(focused, kAXRoleAttribute) as? String ?? "") { return focused }
        // Arrowing through results can move AX focus off the search field.
        mutex.lock(); let previous = field; mutex.unlock()
        if let previous {
            var previousPID: pid_t = 0; AXUIElementGetPid(previous, &previousPID)
            if previousPID == pid { return previous }
        }
        return nil
    }
    private func scan(forSubmission: Bool = false) {
        let current = focusedField()
        mutex.lock()
        isSpotlight = current != nil; observedAt = Date()
        guard let current else {
            armed = false; invalid = false; field = nil; cleanQuery = ""; mutex.unlock(); return
        }
        if let field, !CFEqual(field, current) { armed = false; cleanQuery = ""; invalid = false }
        field = current
        let submitting = enterPending
        let typing = Date().timeIntervalSince(lastKeyAt) < 0.06
        mutex.unlock()
        if (typing || submitting) && !forSubmission { return }
        guard let raw = value(current, kAXValueAttribute) as? String else { return }
        // Keep the marker visible while editing. Only submission may strip it.
        let marked = SpotlightSelectionPolicy.markedQuery(raw)
        mutex.lock()
        armed = marked != nil
        invalid = raw.contains("`") && marked == nil
        cleanQuery = marked ?? raw
        mutex.unlock()
    }
    private func submit() {
        defer { mutex.lock(); enterPending = false; mutex.unlock() }
        scan(forSubmission: true)
        mutex.lock()
        let expected = cleanQuery; let valid = armed && !invalid && !expected.isEmpty
        let submittedRevision = revision
        mutex.unlock()
        guard valid, let field = focusedField(),
              let raw = value(field, kAXValueAttribute) as? String,
              SpotlightSelectionPolicy.markedQuery(raw) == expected,
              AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, expected as CFString) == .success else { fail(); return }
        // Resolve the exact selected result after Spotlight processes the clean query.
        Thread.sleep(forTimeInterval: 0.15)
        var pid: pid_t = 0; AXUIElementGetPid(field, &pid)
        let app = AXUIElementCreateApplication(pid)
        guard let window = element(value(app, kAXFocusedWindowAttribute)) else { fail(); return }
        let deadline = Date(timeIntervalSinceNow: 0.2)
        var pending: [(AXUIElement, Bool)] = [(window, false)]
        var urls = Set<URL>(); var visited = Set<CFHashCode>()
        while !pending.isEmpty && visited.count < 240 && Date() < deadline {
            let (item, selectedAncestor) = pending.removeFirst()
            guard visited.insert(CFHash(item)).inserted else { continue }
            let role = value(item, kAXRoleAttribute) as? String ?? ""
            if [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"].contains(role) { continue }
            let selected = selectedAncestor || (value(item, kAXSelectedAttribute) as? Bool == true)
            if selected {
                for attribute in [kAXURLAttribute, "AXDocument", kAXValueAttribute] {
                    if let raw = value(item, attribute), let url = SpotlightSelectionPolicy.applicationURL(String(describing: raw)) { urls.insert(url) }
                }
            }
            let selectedChildren = (value(item, kAXSelectedChildrenAttribute) as? [AXUIElement] ?? [])
                + (value(item, kAXSelectedRowsAttribute) as? [AXUIElement] ?? [])
            pending.insert(contentsOf: selectedChildren.map { ($0, true) }, at: 0)
            pending.append(contentsOf: (value(item, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { ($0, selected) })
        }
        mutex.lock(); let unchanged = revision == submittedRevision; mutex.unlock()
        guard unchanged, value(field, kAXValueAttribute) as? String == expected,
              urls.count == 1, let url = urls.first,
              Bundle(url: url)?.bundleIdentifier != nil else { fail(); return }
        // Cancel Spotlight rather than pressing its result: native Return would
        // launch/activate it before Intent has applied name-first and mode rules.
        guard AXUIElementPerformAction(window, kAXCancelAction as CFString) == .success
                || AXUIElementPerformAction(field, kAXCancelAction as CFString) == .success
                || AXUIElementPerformAction(app, kAXCancelAction as CFString) == .success else { fail(); return }
        mutex.lock(); armed = false; mutex.unlock()
        DispatchQueue.main.async { [weak self] in self?.onApplication?(url) }
    }
    private func fail() {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?("Spotlight did not expose a unique application result that Intent could add safely. Choose the app in Intent’s overview instead.")
        }
    }
    deinit { timer?.cancel() }
}
