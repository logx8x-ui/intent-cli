import AppKit
import Foundation
import IntentCore
import IntentLock

@MainActor
protocol IntentOverlayPresenting: AnyObject {
    func showOverlay(animated: Bool)
    func hideOverlay(animated: Bool)
    func toggleOverlay()
}

@MainActor
final class IntentAppModel: ObservableObject {
    private static let requireManualFinishKey = "intentRequireManualFinishBeforeSwitching"

    @Published var intentions: [Intention] = []
    @Published var selectedID: String?
    @Published var activeSessionName: String?
    @Published var activeSessionEndsAt: Date?
    @Published var pendingFriction: PendingFriction?
    @Published var errorMessage: String?
    @Published var installedApps: [InstalledApp] = []
    @Published var schedules: [IntentSchedule] = []
    @Published var sessionSwitchWarning: SessionSwitchWarning?
    @Published var requireManualFinishBeforeSwitching: Bool {
        didSet {
            UserDefaults.standard.set(requireManualFinishBeforeSwitching, forKey: Self.requireManualFinishKey)
        }
    }

    weak var overlayPresenter: IntentOverlayPresenting?

    private let store = IntentionStore()
    private let scheduleStore = IntentScheduleStore()
    private let cooldownStore = IntentionCooldownStore()
    private let browserRulesStore = ActiveBrowserRulesStore()
    private var pendingStartIntention: Intention?
    private var pendingReplacementIntention: Intention?
    private var remainingFrictions: [FrictionNode] = []
    private var activeLock: FocusLock?
    private var activeSessionID: String?
    private var undoStack: [[Intention]] = []
    private var activeMoveUndoKeys: Set<String> = []
    private var scheduleTimer: Timer?
    private var sessionLimitTask: Task<Void, Never>?

    init() {
        requireManualFinishBeforeSwitching = UserDefaults.standard.object(
            forKey: Self.requireManualFinishKey
        ) as? Bool ?? true
    }

    var selectedIntention: Intention? {
        guard let selectedID else { return intentions.first }
        return intentions.first { $0.id == selectedID }
    }

    var hasActiveSession: Bool { activeSessionName != nil }

    func load() {
        if installedApps.isEmpty {
            installedApps = AppCatalog.load()
        }

        do {
            intentions = try store.load()
            selectedID = selectedID ?? intentions.first?.id
            undoStack.removeAll()
            activeMoveUndoKeys.removeAll()
            try store.save(intentions)
        } catch {
            errorMessage = "Could not load intentions: \(error)"
            intentions = []
            selectedID = nil
        }

        do {
            schedules = try scheduleStore.load()
        } catch {
            errorMessage = "Could not load schedules: \(error)"
            schedules = []
        }
        startScheduleTimer()
    }

    func save() {
        guard !hasActiveSession else { return }
        do {
            try store.save(intentions)
        } catch {
            errorMessage = "Could not save intentions: \(error)"
        }
    }

    @discardableResult
    func createIntention(at position: GraphPoint) -> String {
        recordUndoSnapshot()
        let intention = Intention(
            name: "New intention",
            icon: "target",
            colorHex: "#F5F5F7",
            folder: "",
            allowedApps: [],
            allowedWebsites: [],
            startupActions: [],
            restrictions: .init(),
            graphPosition: position
        )
        intentions.append(intention)
        selectedID = intention.id
        save()
        return intention.id
    }

    func deleteIntention(id: String) {
        guard !hasActiveSession else { return }
        guard intentions.contains(where: { $0.id == id }) else { return }
        recordUndoSnapshot()
        intentions.removeAll { $0.id == id }
        schedules.removeAll { $0.intentionID == id }
        try? cooldownStore.clear(intentionID: id)
        saveSchedules()
        if selectedID == id {
            selectedID = intentions.first?.id
        }
        save()
    }

    func updateIntention(_ intention: Intention) {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == intention.id }) else {
            return
        }
        guard intentions[index] != intention else { return }
        recordUndoSnapshot()
        intentions[index] = intention
        save()
    }

    func mutateIntention(id: String, _ mutation: (inout Intention) -> Void) {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == id }) else {
            return
        }
        var updated = intentions[index]
        mutation(&updated)
        guard updated != intentions[index] else { return }
        recordUndoSnapshot()
        intentions[index] = updated
        save()
    }

    func moveIntention(id: String, to position: GraphPoint, persist: Bool) {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == id }) else {
            return
        }
        beginMoveUndoIfNeeded(key: "intention:\(id)", persist: persist)
        intentions[index].graphPosition = position
        if persist {
            activeMoveUndoKeys.remove("intention:\(id)")
            save()
        }
    }

    func moveRestriction(intentionID: String, nodeID: String, to position: GraphPoint, persist: Bool) {
        guard !hasActiveSession,
              let intentionIndex = intentions.firstIndex(where: { $0.id == intentionID }),
              let nodeIndex = intentions[intentionIndex].restrictionNodes.firstIndex(where: { $0.id == nodeID }) else {
            return
        }
        let key = "restriction:\(intentionID):\(nodeID)"
        beginMoveUndoIfNeeded(key: key, persist: persist)
        intentions[intentionIndex].restrictionNodes[nodeIndex].position = position
        if persist {
            activeMoveUndoKeys.remove(key)
            save()
        }
    }

    func moveFriction(intentionID: String, nodeID: String, to position: GraphPoint, persist: Bool) {
        guard !hasActiveSession,
              let intentionIndex = intentions.firstIndex(where: { $0.id == intentionID }),
              let nodeIndex = intentions[intentionIndex].frictionNodes.firstIndex(where: { $0.id == nodeID }) else {
            return
        }
        let key = "friction:\(intentionID):\(nodeID)"
        beginMoveUndoIfNeeded(key: key, persist: persist)
        intentions[intentionIndex].frictionNodes[nodeIndex].position = position
        if persist {
            activeMoveUndoKeys.remove(key)
            save()
        }
    }

    @discardableResult
    func addRestriction(to intentionID: String, at position: GraphPoint) -> String? {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == intentionID }) else {
            return nil
        }
        recordUndoSnapshot()
        let node = RestrictionNode(kind: .allowBrowserSearches, position: position)
        intentions[index].restrictionNodes.append(node)
        selectedID = intentionID
        save()
        return node.id
    }

    @discardableResult
    func addFriction(to intentionID: String, at position: GraphPoint) -> String? {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == intentionID }) else {
            return nil
        }
        recordUndoSnapshot()
        let node = FrictionNode(
            friction: .typedPhrase("I want to do this right now"),
            position: position
        )
        intentions[index].frictionNodes.append(node)
        selectedID = intentionID
        save()
        return node.id
    }

    func undoLastChange() {
        guard !hasActiveSession, let previous = undoStack.popLast() else { return }
        intentions = previous
        activeMoveUndoKeys.removeAll()
        if let selectedID, !intentions.contains(where: { $0.id == selectedID }) {
            self.selectedID = intentions.first?.id
        }
        save()
    }

    @discardableResult
    func createSchedule(intentionID: String, scheduledAt: Date = Date()) -> String? {
        guard intentions.contains(where: { $0.id == intentionID }) else { return nil }
        let schedule = IntentSchedule(
            intentionID: intentionID,
            recurrence: .once,
            scheduledAt: scheduledAt
        )
        schedules.append(schedule)
        saveSchedules()
        return schedule.id
    }

    func updateSchedule(_ schedule: IntentSchedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        var normalized = schedule
        normalized.weekdays = Array(Set(schedule.weekdays)).sorted()
        schedules[index] = normalized
        saveSchedules()
    }

    func deleteSchedule(id: String) {
        schedules.removeAll { $0.id == id }
        saveSchedules()
    }

    func requestStart(_ intention: Intention) {
        do {
            if let nextAllowedDate = try cooldownStore.nextAllowedDate(for: intention.id) {
                errorMessage = "\(intention.name) is cooling down. Try again in \(Self.durationText(until: nextAllowedDate))."
                return
            }
        } catch {
            errorMessage = "Could not check \(intention.name)'s cooldown: \(error)"
            return
        }

        guard !intention.allowedApps.isEmpty else {
            errorMessage = "Add at least one allowed app before starting this intention."
            return
        }
        let unsupportedBrowsers = intention.allowedApps.filter {
            $0.isBrowser && !Self.supportedBrowserBundleIdentifiers.contains($0.bundleIdentifier)
        }
        if !unsupportedBrowsers.isEmpty {
            let names = unsupportedBrowsers.map(\.name).joined(separator: ", ")
            errorMessage = "Browser locking currently supports Firefox and Chrome. Replace \(names) with one of those browsers before starting this intention."
            return
        }
        selectedID = intention.id

        guard hasActiveSession else {
            sessionSwitchWarning = nil
            beginStartFlow(for: intention)
            return
        }
        guard activeSessionID != intention.id else { return }

        if requireManualFinishBeforeSwitching {
            let activeName = activeSessionName ?? "An intention"
            sessionSwitchWarning = SessionSwitchWarning(
                message: "\(activeName) is running. Press Cmd+Shift+M to finish it before starting \(intention.name)."
            )
            return
        }

        sessionSwitchWarning = nil
        pendingReplacementIntention = intention
        activeLock?.stop()
    }

    private func beginStartFlow(for intention: Intention) {
        let frictions = intention.orderedFrictionNodes
        guard !frictions.isEmpty else {
            start(intention)
            return
        }

        pendingStartIntention = intention
        remainingFrictions = frictions
        presentNextFriction()
    }

    func requestStart(intentionID: String) {
        guard let intention = intentions.first(where: { $0.id == intentionID }) else {
            errorMessage = "Could not find that intention."
            return
        }
        selectedID = intention.id
        requestStart(intention)
    }

    func submitFriction(_ input: String) {
        guard let pendingFriction else { return }
        guard pendingFriction.validate(input) else {
            errorMessage = "That friction check is not complete yet."
            return
        }
        completeCurrentFriction()
    }

    func completeCurrentFriction() {
        guard pendingFriction != nil else { return }
        self.pendingFriction = nil
        if !remainingFrictions.isEmpty {
            remainingFrictions.removeFirst()
        }

        if remainingFrictions.isEmpty {
            guard let intention = pendingStartIntention else { return }
            pendingStartIntention = nil
            start(intention)
        } else {
            presentNextFriction()
        }
    }

    func cancelFriction() {
        pendingFriction = nil
        pendingStartIntention = nil
        remainingFrictions = []
    }

    func endActiveSession() {
        sessionSwitchWarning = nil
        activeLock?.stop()
    }

    func showOverlay() {
        overlayPresenter?.showOverlay(animated: true)
    }

    func hideOverlay() {
        overlayPresenter?.hideOverlay(animated: true)
    }

    func toggleOverlay() {
        overlayPresenter?.toggleOverlay()
    }

    private func presentNextFriction() {
        guard let intention = pendingStartIntention,
              let node = remainingFrictions.first else {
            return
        }
        let completed = intention.frictionNodes.count - remainingFrictions.count
        pendingFriction = PendingFriction(
            intentionID: intention.id,
            intentionName: intention.name,
            node: node,
            step: completed + 1,
            totalSteps: intention.frictionNodes.count
        )
    }

    private func start(_ intention: Intention) {
        for browser in requiredBrowserGuards(for: intention) {
            let heartbeatStore = BrowserGuardHeartbeatStore(
                fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser.bundleIdentifier)
            )
            if !heartbeatStore.isFresh(maxAge: 5) {
                errorMessage = "\(browser.name) browser locking is not connected. Load Intent Browser Guard in \(browser.name), then start this intention again."
                return
            }

            let stateStore = BrowserGuardStateStore(
                fileURL: BrowserGuardStateStore.fileURL(for: browser.bundleIdentifier)
            )
            if !stateStore.isEnabled() {
                errorMessage = "Intent Browser Guard is turned off in \(browser.name). Open its toolbar popup and switch it on, then start this intention again."
                return
            }
        }

        let spec = FocusSessionSpec.make(for: intention)
        let websitesByBrowser = Dictionary(uniqueKeysWithValues: requiredBrowserGuards(for: intention).map { browser in
            let websites = intention.websites(for: browser.bundleIdentifier).map(\.value)
            return (browser.bundleIdentifier, websites.isEmpty ? ["intent.invalid"] : websites)
        })
        let firefoxWebsites = websitesByBrowser["org.mozilla.firefox"] ?? []
        let rules = ActiveBrowserRules(
            active: true,
            // A non-matching sentinel keeps already-installed Browser Guard 0.1.3 builds strict
            // when Firefox is allowed but the intention has no website spikes.
            allowedWebsites: firefoxWebsites,
            allowedWebsitesByBrowser: websitesByBrowser,
            blockTabSwitching: true,
            blockNavigation: true,
            blockNewTabs: false,
            allowGoogleSearchTabs: intention.browserSearchesAllowed
        )

        do {
            try browserRulesStore.write(rules)
        } catch {
            errorMessage = "Could not write browser rules: \(error)"
            return
        }

        let lock = FocusLock(spec: spec)
        activeLock = lock
        activeSessionID = intention.id
        activeSessionName = intention.name
        scheduleSessionLimit(for: intention)
        overlayPresenter?.hideOverlay(animated: true)

        Thread.detachNewThread {
            let renewalTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            renewalTimer.schedule(deadline: .now() + 1, repeating: 1)
            renewalTimer.setEventHandler {
                try? ActiveBrowserRulesStore().write(rules.refreshed())
            }
            renewalTimer.resume()

            let failureMessage: String?
            do {
                try lock.run()
                failureMessage = nil
            } catch {
                failureMessage = "Could not start session: \(error)"
            }

            renewalTimer.cancel()
            try? ActiveBrowserRulesStore().clear()
            Task { @MainActor in
                let replacement = self.pendingReplacementIntention
                self.pendingReplacementIntention = nil
                self.sessionLimitTask?.cancel()
                self.sessionLimitTask = nil
                self.activeSessionEndsAt = nil
                if failureMessage == nil {
                    self.beginCooldown(for: intention)
                } else {
                    self.errorMessage = failureMessage
                }
                self.activeLock = nil
                self.activeSessionID = nil
                self.activeSessionName = nil
                self.overlayPresenter?.showOverlay(animated: true)
                if let replacement {
                    self.requestStart(replacement)
                }
            }
        }
    }

    private func scheduleSessionLimit(for intention: Intention) {
        sessionLimitTask?.cancel()
        guard let minutes = intention.timerMinutes else {
            activeSessionEndsAt = nil
            sessionLimitTask = nil
            return
        }

        let duration = TimeInterval(minutes * 60)
        activeSessionEndsAt = Date().addingTimeInterval(duration)
        sessionLimitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  self.activeSessionID == intention.id else {
                return
            }
            self.errorMessage = "\(intention.name)'s \(minutes)-minute timer finished."
            self.activeLock?.stop()
        }
    }

    private func beginCooldown(for intention: Intention) {
        guard let minutes = intention.coolDownMinutes else { return }
        do {
            try cooldownStore.begin(intentionID: intention.id, minutes: minutes)
        } catch {
            errorMessage = "Could not save \(intention.name)'s cooldown: \(error)"
        }
    }

    private static func durationText(until date: Date, now: Date = Date()) -> String {
        let remaining = max(1, Int(date.timeIntervalSince(now).rounded(.up)))
        let hours = remaining / 3_600
        let minutes = (remaining % 3_600) / 60
        let seconds = remaining % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private func requiredBrowserGuards(for intention: Intention) -> [AllowedApp] {
        intention.allowedApps.filter {
            Self.supportedBrowserBundleIdentifiers.contains($0.bundleIdentifier)
        }
    }

    private static let supportedBrowserBundleIdentifiers: Set<String> = [
        "org.mozilla.firefox",
        "com.google.Chrome"
    ]

    private func saveSchedules() {
        do {
            try scheduleStore.save(schedules)
        } catch {
            errorMessage = "Could not save schedules: \(error)"
        }
    }

    private func startScheduleTimer() {
        guard scheduleTimer == nil else { return }
        let modelBox = WeakIntentAppModel(self)
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                modelBox.value?.runDueSchedule()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
        runDueSchedule()
    }

    private func runDueSchedule(at now: Date = Date()) {
        guard !hasActiveSession, pendingFriction == nil else { return }
        guard let index = schedules.indices.first(where: { index in
            guard let key = schedules[index].triggerKeyIfDue(at: now) else { return false }
            return schedules[index].lastTriggeredKey != key
        }),
        let key = schedules[index].triggerKeyIfDue(at: now),
        let intention = intentions.first(where: { $0.id == schedules[index].intentionID }) else {
            return
        }

        schedules[index].lastTriggeredKey = key
        if schedules[index].recurrence == .once {
            schedules[index].isEnabled = false
        }
        saveSchedules()
        overlayPresenter?.showOverlay(animated: true)
        requestStart(intention)
    }

    private func recordUndoSnapshot() {
        guard !hasActiveSession else { return }
        if undoStack.last != intentions {
            undoStack.append(intentions)
            if undoStack.count > 100 {
                undoStack.removeFirst(undoStack.count - 100)
            }
        }
    }

    private func beginMoveUndoIfNeeded(key: String, persist: Bool) {
        if !activeMoveUndoKeys.contains(key) {
            recordUndoSnapshot()
            activeMoveUndoKeys.insert(key)
        }
        if persist {
            activeMoveUndoKeys.remove(key)
        }
    }
}

struct SessionSwitchWarning: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

private final class WeakIntentAppModel: @unchecked Sendable {
    weak var value: IntentAppModel?

    init(_ value: IntentAppModel) {
        self.value = value
    }
}

struct PendingFriction: Identifiable {
    let id = UUID()
    let intentionID: String
    let intentionName: String
    let node: FrictionNode
    let step: Int
    let totalSteps: Int

    var friction: Friction { node.friction }

    func validate(_ input: String) -> Bool {
        switch friction {
        case .none, .countdown:
            return true
        case .typedPhrase(let phrase):
            return input == phrase
        case .reasonPrompt:
            return !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .taskChecklist:
            return input == "done"
        case .timeBudget(let minutes):
            return input == "\(minutes)"
        }
    }
}
