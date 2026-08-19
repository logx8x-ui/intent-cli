import AppKit
import Foundation
import IntentCore
import IntentLock

@MainActor
protocol IntentOverlayPresenting: AnyObject {
    var isOverlayVisible: Bool { get }
    func showOverlay(animated: Bool)
    func hideOverlay(animated: Bool)
    func toggleOverlay()
    func showSessionTimer(name: String, endsAt: Date)
    func hideSessionTimer()
}

@MainActor
final class IntentAppModel: ObservableObject {
    private static let requireManualFinishKey = "intentRequireManualFinishBeforeSwitching"

    @Published var intentions: [Intention] = []
    @Published var selectedID: String?
    @Published var activeSessionName: String?
    @Published var activeSessionIsLeisure = false
    @Published var activeSessionEndsAt: Date?
    @Published var zeroDriftEndsAt: Date?
    @Published var cooldownExpirations: [String: Date] = [:]
    @Published var pendingFriction: PendingFriction?
    @Published var pendingEndTimeRequest: PendingEndTimeRequest?
    @Published var errorMessage: String?
    @Published var installedApps: [InstalledApp] = []
    @Published var schedules: [IntentSchedule] = []
    @Published var sessionSwitchWarning: SessionSwitchWarning?
    @Published var shortcutWarning: String?
    @Published var purposeModeIsResolving = false
    @Published var purposeModeError: String?
    @Published var pendingPurposeSessionSave: PurposeSessionSaveCandidate?
    @Published private(set) var overlayPresentationID = UUID()
    @Published var requireManualFinishBeforeSwitching: Bool {
        didSet {
            UserDefaults.standard.set(requireManualFinishBeforeSwitching, forKey: Self.requireManualFinishKey)
        }
    }

    weak var overlayPresenter: IntentOverlayPresenting?

    private let store = IntentionStore()
    private let scheduleStore = IntentScheduleStore()
    private let cooldownStore = IntentionCooldownStore()
    private let zeroDriftStore = ZeroDriftStateStore()
    private let browserRulesStore = ActiveBrowserRulesStore()
    private var pendingStartIntention: Intention?
    private var pendingRuntimeEndDate: Date?
    private var pendingReplacementIntention: Intention?
    private var remainingFrictions: [FrictionNode] = []
    private var activeLock: FocusLock?
    private var zeroDriftIdleLock: FocusLock?
    private var activeSessionID: String?
    private var activeSessionIntention: Intention?
    private var purposeTemporaryIntention: Intention?
    private var purposeStatedPrompt: String?
    private var purposeUsageTracker: PurposeSessionUsageTracker?
    private var pendingZeroDriftStart: (intention: Intention, runtimeEndDate: Date?)?
    private var undoStack: [[Intention]] = []
    private var activeMoveUndoKeys: Set<String> = []
    private var scheduleTimer: Timer?
    private var sessionLimitTask: Task<Void, Never>?
    private var zeroDriftLimitTask: Task<Void, Never>?

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

    var isZeroDriftActive: Bool {
        guard let zeroDriftEndsAt else { return false }
        return zeroDriftEndsAt > Date()
    }

    var zeroDriftStatusText: String? {
        guard let zeroDriftEndsAt, zeroDriftEndsAt > Date() else { return nil }
        return Self.durationText(until: zeroDriftEndsAt)
    }

    var activeSessionCanFinishManually: Bool {
        guard let intention = activeSessionIntention,
              intention.sessionLocksManualFinish,
              let activeSessionEndsAt,
              activeSessionEndsAt > Date() else {
            return true
        }
        return false
    }

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
        do {
            cooldownExpirations = try cooldownStore.activeCooldowns()
        } catch {
            cooldownExpirations = [:]
        }
        restoreZeroDriftIfNeeded()
        startScheduleTimer()
    }

    func save() {
        guard !hasActiveSession else { return }
        do {
            let namedIntentions = intentions.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            try store.save(namedIntentions)
        } catch {
            errorMessage = "Could not save intentions: \(error)"
        }
    }

    @discardableResult
    func createIntention(at position: GraphPoint) -> String {
        recordUndoSnapshot()
        let intention = Intention(
            name: "",
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

    @discardableResult
    func addAIIntentions(_ suggestions: [AIIntentionSuggestion]) -> [String] {
        guard !hasActiveSession, !suggestions.isEmpty else { return [] }

        let availableApps = installedApps.map {
            AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier)
        }
        let validated = AIIntentionPlan(intentions: suggestions)
            .validated(against: availableApps)
            .intentions
            .filter { $0.isLeisure || !$0.appBundleIdentifiers.isEmpty }
        guard !validated.isEmpty else { return [] }

        let appsByIdentifier = Dictionary(
            uniqueKeysWithValues: availableApps.map { ($0.bundleIdentifier, $0) }
        )
        var occupied = intentions.map(\.graphPosition)
        var imported: [Intention] = []

        for (index, suggestion) in validated.enumerated() {
            let position = availableAIPosition(index: index, occupied: occupied)
            let allowedApps = suggestion.appBundleIdentifiers.compactMap { appsByIdentifier[$0] }
            let allowedWebsites = suggestion.websites.map {
                AllowedWebsite($0.value, browserBundleIdentifier: $0.browserBundleIdentifier)
            }
            let restrictionNodes = suggestion.restrictions.enumerated().map { offset, restriction in
                RestrictionNode(
                    kind: restriction.kind,
                    position: Self.aiConnectedNodePosition(
                        center: position,
                        index: offset,
                        total: suggestion.restrictions.count,
                        above: true
                    ),
                    excludedResourceIDs: restriction.resourceIDs,
                    durationMinutes: restriction.kind == .timer || restriction.kind == .coolDown
                        ? max(1, restriction.durationMinutes)
                        : nil,
                    showsRemainingTime: restriction.kind == .timer || restriction.kind == .coolDown
                        ? true
                        : nil,
                    locksSessionUntilTimerEnds: restriction.kind == .timer ? true : nil
                )
            }
            let frictionNodes = suggestion.frictions.enumerated().map { offset, friction in
                FrictionNode(
                    friction: friction.friction(intentionName: suggestion.name),
                    position: Self.aiConnectedNodePosition(
                        center: position,
                        index: offset,
                        total: suggestion.frictions.count,
                        above: false
                    )
                )
            }

            imported.append(Intention(
                name: suggestion.name,
                icon: "sparkles",
                colorHex: "#F5F5F7",
                folder: "",
                allowedApps: allowedApps,
                allowedWebsites: allowedWebsites,
                startupActions: [],
                restrictions: .init(),
                graphPosition: position,
                restrictionNodes: restrictionNodes,
                frictionNodes: frictionNodes,
                isLeisure: suggestion.isLeisure
            ))
            occupied.append(position)
        }

        recordUndoSnapshot()
        intentions.append(contentsOf: imported)
        selectedID = imported.first?.id
        save()
        return imported.map(\.id)
    }

    func startPurposeSession(
        for rawPurpose: String,
        liveInterpretation: PurposeLiveInterpretation? = nil
    ) async {
        let purpose = rawPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !purpose.isEmpty else { return }
        guard !hasActiveSession else {
            purposeModeError = "Finish the current intention before choosing a new purpose."
            return
        }

        purposeModeIsResolving = true
        purposeModeError = nil
        defer { purposeModeIsResolving = false }

        if let existing = matchedIntention(for: purpose, minimumScore: 0.88),
           purposeInterpretation(liveInterpretation, isCompatibleWith: existing) {
            requestStart(existing)
            return
        }

        let availableApps = installedApps.map {
            AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier)
        }
        let existingNames = intentions
            .map(\.name)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ", ")
        let includedAppNames = liveInterpretation?.includedAppBundleIdentifiers.compactMap { identifier in
            availableApps.first { $0.bundleIdentifier == identifier }?.name
        } ?? []
        let excludedAppNames = liveInterpretation?.excludedAppBundleIdentifiers.compactMap { identifier in
            availableApps.first { $0.bundleIdentifier == identifier }?.name
        } ?? []
        let includedIntentionNames = liveInterpretation?.includedIntentionIDs.compactMap { id in
            intentions.first { $0.id == id }?.name
        } ?? []
        let liveResolution = """
        Final live interpretation after applying the person's corrections in order:
        - Keep these apps: \(includedAppNames.isEmpty ? "No app was explicitly resolved" : includedAppNames.joined(separator: ", "))
        - Never include these removed apps: \(excludedAppNames.isEmpty ? "None" : excludedAppNames.joined(separator: ", "))
        - Referenced saved intentions: \(includedIntentionNames.isEmpty ? "None" : includedIntentionNames.joined(separator: ", "))
        Later corrections override earlier words. Never re-add an app listed as removed.
        """
        let description = """
        Start one immediate focused session for this purpose: \(purpose)

        Existing intention names: \(existingNames.isEmpty ? "None" : existingNames)
        If this is clearly the same task as an existing intention, use that exact existing name. Otherwise choose only the installed apps and narrow websites needed right now. Do not add friction, timers, cooldowns, or leisure mode unless the person explicitly requested them.

        \(liveResolution)
        """

        do {
            let plan = try await IntentAIService().generate(
                description: description,
                installedApps: availableApps,
                mode: .single
            ).validated(against: availableApps)
            guard var suggestion = plan.intentions.first else {
                purposeModeError = "Intent could not identify the apps needed for that purpose. Try naming the task or app more specifically."
                return
            }

            if let liveInterpretation {
                let included = liveInterpretation.includedAppBundleIdentifiers
                let excluded = Set(liveInterpretation.excludedAppBundleIdentifiers)
                if liveInterpretation.limitsAppsToSelection, !included.isEmpty {
                    suggestion.appBundleIdentifiers = included
                } else {
                    for identifier in included where !suggestion.appBundleIdentifiers.contains(identifier) {
                        suggestion.appBundleIdentifiers.append(identifier)
                    }
                }
                suggestion.appBundleIdentifiers.removeAll { excluded.contains($0) }
                suggestion.websites.removeAll { excluded.contains($0.browserBundleIdentifier) }
            }

            let suggestedPurpose = [suggestion.name, suggestion.purpose]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if let existing = matchedIntention(for: suggestedPurpose, minimumScore: 0.88),
               purposeInterpretation(liveInterpretation, isCompatibleWith: existing) {
                requestStart(existing)
                return
            }

            let appsByIdentifier = Dictionary(
                uniqueKeysWithValues: availableApps.map { ($0.bundleIdentifier, $0) }
            )
            guard let temporary = makePurposeIntention(
                from: suggestion,
                appsByIdentifier: appsByIdentifier
            ) else {
                purposeModeError = "Intent could not find a necessary installed app for that task. Try mentioning the app you want to use."
                return
            }

            purposeTemporaryIntention = temporary
            purposeStatedPrompt = purpose
            requestStart(temporary)
        } catch {
            purposeModeError = error.localizedDescription
        }
    }

    func savePurposeSessionCandidate() {
        guard var intention = pendingPurposeSessionSave?.intention else { return }
        let position = availableAIPosition(index: 0, occupied: intentions.map(\.graphPosition))
        let deltaX = position.x - intention.graphPosition.x
        let deltaY = position.y - intention.graphPosition.y
        intention.graphPosition = position
        intention.restrictionNodes = intention.restrictionNodes.map { node in
            var moved = node
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }
        intention.frictionNodes = intention.frictionNodes.map { node in
            var moved = node
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }

        recordUndoSnapshot()
        intentions.append(intention)
        selectedID = intention.id
        pendingPurposeSessionSave = nil
        save()
    }

    func discardPurposeSessionCandidate() {
        guard let intentionID = pendingPurposeSessionSave?.intention.id else { return }
        try? cooldownStore.clear(intentionID: intentionID)
        cooldownExpirations.removeValue(forKey: intentionID)
        if selectedID == intentionID {
            selectedID = intentions.first?.id
        }
        pendingPurposeSessionSave = nil
    }

    @discardableResult
    func addDraftIntention(_ draft: Intention, at position: GraphPoint) -> String? {
        guard !hasActiveSession,
              !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.allowedApps.isEmpty else {
            return nil
        }

        let deltaX = position.x - draft.graphPosition.x
        let deltaY = position.y - draft.graphPosition.y
        var imported = draft
        imported.id = UUID().uuidString
        imported.graphPosition = position
        imported.restrictionNodes = draft.restrictionNodes.map { node in
            var moved = node
            moved.id = UUID().uuidString
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }
        imported.frictionNodes = draft.frictionNodes.map { node in
            var moved = node
            moved.id = UUID().uuidString
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }

        recordUndoSnapshot()
        intentions.append(imported)
        selectedID = imported.id
        save()
        return imported.id
    }

    @discardableResult
    func replaceIntention(id: String, with draft: Intention) -> Bool {
        guard !hasActiveSession,
              !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.allowedApps.isEmpty,
              let index = intentions.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let existing = intentions[index]
        let deltaX = existing.graphPosition.x - draft.graphPosition.x
        let deltaY = existing.graphPosition.y - draft.graphPosition.y
        var updated = draft
        updated.id = existing.id
        updated.graphPosition = existing.graphPosition
        updated.restrictionNodes = draft.restrictionNodes.map { node in
            var moved = node
            moved.id = UUID().uuidString
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }
        updated.frictionNodes = draft.frictionNodes.map { node in
            var moved = node
            moved.id = UUID().uuidString
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }

        recordUndoSnapshot()
        intentions[index] = updated
        selectedID = id
        save()
        return true
    }

    func intentionReferenced(in prompt: String) -> Intention? {
        switch AIIntentionMentionResolver.resolvePrimaryTarget(in: prompt, intentions: intentions) {
        case .resolved(let intentionID, _):
            return intentions.first { $0.id == intentionID }
        case .missing, .ambiguous, .none:
            return nil
        }
    }

    func resolveAIMention(in prompt: String) -> AIIntentionMention? {
        AIIntentionMentionResolver.resolvePrimaryTarget(in: prompt, intentions: intentions)
    }

    func moveIntentionGroup(id: String, to position: GraphPoint, persist: Bool) {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == id }) else {
            return
        }
        let previous = intentions[index].graphPosition
        let deltaX = position.x - previous.x
        let deltaY = position.y - previous.y
        beginMoveUndoIfNeeded(key: "intention-group:\(id)", persist: persist)
        intentions[index].graphPosition = position
        intentions[index].restrictionNodes = intentions[index].restrictionNodes.map { node in
            var moved = node
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }
        intentions[index].frictionNodes = intentions[index].frictionNodes.map { node in
            var moved = node
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }
        if persist {
            activeMoveUndoKeys.remove("intention-group:\(id)")
            save()
        }
    }

    func discardIfUnnamed(id: String) {
        guard !hasActiveSession,
              let intention = intentions.first(where: { $0.id == id }),
              intention.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        intentions.removeAll { $0.id == id }
        schedules.removeAll { $0.intentionID == id }
        try? cooldownStore.clear(intentionID: id)
        cooldownExpirations.removeValue(forKey: id)
        saveSchedules()
        if selectedID == id {
            selectedID = intentions.first?.id
        }
        save()
    }

    func deleteIntention(id: String) {
        guard !hasActiveSession else { return }
        guard intentions.contains(where: { $0.id == id }) else { return }
        recordUndoSnapshot()
        intentions.removeAll { $0.id == id }
        schedules.removeAll { $0.intentionID == id }
        try? cooldownStore.clear(intentionID: id)
        cooldownExpirations.removeValue(forKey: id)
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
    func addRestriction(
        to intentionID: String,
        at position: GraphPoint,
        kind: RestrictionKind = .allowBrowserSearches
    ) -> String? {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == intentionID }) else {
            return nil
        }
        recordUndoSnapshot()
        let node = RestrictionNode(kind: kind, position: position)
        intentions[index].restrictionNodes.append(node)
        selectedID = intentionID
        save()
        return node.id
    }

    @discardableResult
    func addFriction(
        to intentionID: String,
        at position: GraphPoint,
        friction: Friction = .typedPhrase("I want to do this right now")
    ) -> String? {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == intentionID }) else {
            return nil
        }
        recordUndoSnapshot()
        let node = FrictionNode(
            friction: friction,
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
            scheduledAt: scheduledAt,
            lastLocalModifiedAt: Date()
        )
        schedules.append(schedule)
        saveSchedules()
        return schedule.id
    }

    func updateSchedule(_ schedule: IntentSchedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        var normalized = schedule
        normalized.weekdays = Array(Set(schedule.weekdays)).sorted()
        normalized.lastLocalModifiedAt = Date()
        if var sync = normalized.sync {
            sync.lastLocalModifiedAt = normalized.lastLocalModifiedAt
            normalized.sync = sync
        }
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
                cooldownExpirations[intention.id] = nextAllowedDate
                errorMessage = "\(intention.name) is cooling down. Try again in \(Self.durationText(until: nextAllowedDate))."
                return
            }
            cooldownExpirations.removeValue(forKey: intention.id)
        } catch {
            errorMessage = "Could not check \(intention.name)'s cooldown: \(error)"
            return
        }

        guard intention.isLeisure || !intention.allowedApps.isEmpty else {
            errorMessage = "Add at least one allowed app before starting this intention."
            return
        }
        let unsupportedBrowsers = intention.isLeisure ? [] : intention.allowedApps.filter {
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
                message: "\(activeName) is running. Press \(FinishShortcutStore.load().displayName) to finish it before starting \(intention.name)."
            )
            return
        }

        guard activeSessionCanFinishManually else {
            sessionSwitchWarning = SessionSwitchWarning(
                message: "\(activeSessionName ?? "This intention") is locked until its scheduled finish."
            )
            return
        }

        sessionSwitchWarning = nil
        pendingReplacementIntention = intention
        activeLock?.stop()
    }

    private func beginStartFlow(for intention: Intention) {
        pendingStartIntention = intention
        pendingRuntimeEndDate = nil
        remainingFrictions = intention.orderedFrictionNodes

        if intention.requiresRuntimeEndTime {
            pendingEndTimeRequest = PendingEndTimeRequest(intention: intention)
            return
        }

        continueStartFlow()
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
            continueStartFlow()
        } else {
            presentNextFriction()
        }
    }

    func cancelFriction() {
        clearPendingPurposeStart()
        pendingFriction = nil
        pendingStartIntention = nil
        pendingRuntimeEndDate = nil
        remainingFrictions = []
    }

    func confirmEndTime(_ date: Date) {
        guard pendingEndTimeRequest != nil else { return }
        let calendar = Calendar.autoupdatingCurrent
        let components = calendar.dateComponents([.hour, .minute], from: date)
        pendingRuntimeEndDate = calendar.nextDate(
            after: Date(),
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) ?? date
        pendingEndTimeRequest = nil
        continueStartFlow()
    }

    func cancelEndTimeSelection() {
        clearPendingPurposeStart()
        pendingEndTimeRequest = nil
        pendingFriction = nil
        pendingStartIntention = nil
        pendingRuntimeEndDate = nil
        remainingFrictions = []
    }

    func endActiveSession() {
        sessionSwitchWarning = nil
        guard activeSessionCanFinishManually else {
            if let activeSessionEndsAt {
                errorMessage = "This intention is locked for another \(Self.durationText(until: activeSessionEndsAt))."
            }
            return
        }
        activeLock?.stop()
    }

    func activateZeroDrift(until endDate: Date) {
        guard endDate > Date() else {
            errorMessage = "Choose a Zero Drift finish time in the future."
            return
        }

        let state = ZeroDriftState(startedAt: Date(), endsAt: endDate)
        do {
            try zeroDriftStore.save(state)
        } catch {
            errorMessage = "Could not save Zero Drift: \(error)"
            return
        }

        zeroDriftEndsAt = endDate
        scheduleZeroDriftLimit(until: endDate)
        showOverlay()
        startZeroDriftIdleLockIfNeeded()
    }

    func showOverlay() {
        overlayPresentationID = UUID()
        overlayPresenter?.showOverlay(animated: true)
    }

    func hideOverlay() {
        guard !isZeroDriftActive || hasActiveSession else {
            errorMessage = "Zero Drift is active. Start an intention before hiding Intent."
            showOverlay()
            return
        }
        overlayPresenter?.hideOverlay(animated: true)
    }

    func toggleOverlay() {
        if isZeroDriftActive, !hasActiveSession {
            showOverlay()
            return
        }
        if overlayPresenter?.isOverlayVisible == true {
            overlayPresenter?.hideOverlay(animated: true)
        } else {
            showOverlay()
        }
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

    private func continueStartFlow() {
        guard let intention = pendingStartIntention else { return }
        if !remainingFrictions.isEmpty {
            presentNextFriction()
            return
        }

        let runtimeEndDate = pendingRuntimeEndDate
        pendingStartIntention = nil
        pendingRuntimeEndDate = nil
        start(intention, runtimeEndDate: runtimeEndDate)
    }

    private func start(_ intention: Intention, runtimeEndDate: Date? = nil) {
        if let zeroDriftIdleLock {
            pendingZeroDriftStart = (intention, runtimeEndDate)
            zeroDriftIdleLock.stop()
            return
        }

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

        let spec = FocusSessionSpec.make(
            for: intention,
            finishShortcut: FinishShortcutStore.load().focusShortcut
        )
        let websitesByBrowser = Dictionary(uniqueKeysWithValues: requiredBrowserGuards(for: intention).map { browser in
            let websites = intention.websites(for: browser.bundleIdentifier).map(\.value)
            return (browser.bundleIdentifier, websites.isEmpty ? ["intent.invalid"] : websites)
        })
        let firefoxWebsites = websitesByBrowser["org.mozilla.firefox"] ?? []
        let startupWebsitesByBrowser = Dictionary(
            grouping: spec.startupSteps.compactMap { step -> (String, String)? in
                guard case .openURL(let url, let browserBundleIdentifier) = step else {
                    return nil
                }
                return (browserBundleIdentifier, url)
            },
            by: \.0
        ).mapValues { $0.map(\.1) }
        let rules = intention.isLeisure ? nil : ActiveBrowserRules(
            active: true,
            // A non-matching sentinel keeps already-installed Browser Guard 0.1.3 builds strict
            // when Firefox is allowed but the intention has no website spikes.
            allowedWebsites: firefoxWebsites,
            allowedWebsitesByBrowser: websitesByBrowser,
            startupWebsitesByBrowser: startupWebsitesByBrowser,
            blockTabSwitching: true,
            blockNavigation: true,
            blockNewTabs: false,
            allowGoogleSearchTabs: intention.browserSearchesAllowed
        )

        do {
            if let rules {
                try browserRulesStore.write(rules)
            } else {
                try browserRulesStore.clear()
            }
        } catch {
            errorMessage = "Could not write browser rules: \(error)"
            return
        }

        // Browser Guard owns website-tab creation once its rules are active. The lock
        // only activates each browser so two independent launch paths cannot race.
        let lockSpec = rules == nil ? spec : spec.deferringBrowserWebsiteStartupToGuard()
        let lock = FocusLock(spec: lockSpec)
        activeLock = lock
        activeSessionID = intention.id
        activeSessionIntention = intention
        activeSessionName = intention.name
        activeSessionIsLeisure = intention.isLeisure
        if purposeTemporaryIntention?.id == intention.id {
            let tracker = PurposeSessionUsageTracker(intention: intention)
            purposeUsageTracker = tracker
            tracker.start()
        }
        scheduleSessionLimit(for: intention, runtimeEndDate: runtimeEndDate)
        overlayPresenter?.hideOverlay(animated: true)

        Thread.detachNewThread {
            let renewalTimer: DispatchSourceTimer?
            if let rules {
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler {
                    try? ActiveBrowserRulesStore().write(rules.refreshed())
                }
                timer.resume()
                renewalTimer = timer
            } else {
                renewalTimer = nil
            }

            let failureMessage: String?
            do {
                try lock.run()
                failureMessage = nil
            } catch {
                failureMessage = "Could not start session: \(error)"
            }

            renewalTimer?.cancel()
            try? ActiveBrowserRulesStore().clear()
            Task { @MainActor in
                let replacement = self.pendingReplacementIntention
                let wasPurposeSession = self.purposeTemporaryIntention?.id == intention.id
                let purposeUsage = self.purposeUsageTracker?.stop()
                let statedPurpose = self.purposeStatedPrompt
                self.pendingReplacementIntention = nil
                self.purposeUsageTracker = nil
                self.sessionLimitTask?.cancel()
                self.sessionLimitTask = nil
                self.activeSessionEndsAt = nil
                self.overlayPresenter?.hideSessionTimer()
                if failureMessage == nil {
                    self.beginCooldown(for: intention)
                } else {
                    self.errorMessage = failureMessage
                }
                self.activeLock = nil
                self.activeSessionID = nil
                self.activeSessionIntention = nil
                self.activeSessionName = nil
                self.activeSessionIsLeisure = false
                if failureMessage == nil,
                   wasPurposeSession,
                   let purposeUsage,
                   let statedPurpose {
                    self.pendingPurposeSessionSave = self.makePurposeSaveCandidate(
                        from: intention,
                        statedPurpose: statedPurpose,
                        usage: purposeUsage
                    )
                }
                if wasPurposeSession {
                    self.purposeTemporaryIntention = nil
                    self.purposeStatedPrompt = nil
                }
                self.overlayPresenter?.showOverlay(animated: true)
                if let replacement {
                    self.requestStart(replacement)
                } else {
                    self.startZeroDriftIdleLockIfNeeded()
                }
            }
        }
    }

    private func restoreZeroDriftIfNeeded() {
        do {
            guard let state = try zeroDriftStore.load() else {
                zeroDriftEndsAt = nil
                return
            }
            zeroDriftEndsAt = state.endsAt
            scheduleZeroDriftLimit(until: state.endsAt)
            showOverlay()
            startZeroDriftIdleLockIfNeeded()
        } catch {
            try? zeroDriftStore.clear()
            zeroDriftEndsAt = nil
            errorMessage = "Zero Drift could not be restored: \(error)"
        }
    }

    private func scheduleZeroDriftLimit(until endDate: Date) {
        zeroDriftLimitTask?.cancel()
        let duration = max(0.1, endDate.timeIntervalSinceNow)
        zeroDriftLimitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.zeroDriftEndsAt = nil
            self.zeroDriftLimitTask = nil
            try? self.zeroDriftStore.clear()
            self.zeroDriftIdleLock?.stop()
            self.errorMessage = "Zero Drift finished."
        }
    }

    private func startZeroDriftIdleLockIfNeeded() {
        guard isZeroDriftActive,
              !hasActiveSession,
              zeroDriftIdleLock == nil else {
            return
        }

        let intentBundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.loganmondi.intent"
        let spec = FocusSessionSpec(
            displayName: "Zero Drift",
            startupSteps: [],
            allowedBundleIdentifiers: [intentBundleIdentifier],
            fallbackBundleIdentifier: intentBundleIdentifier,
            strictSingleApp: true,
            blockAppSwitching: true,
            blockNewApps: true,
            keepFocused: true,
            blockBrowserTabEscape: false,
            blockFirefoxChromeClicks: false,
            allowGoogleSearchTabs: false,
            spotifyPlaylistURI: nil,
            allowSpotifyForeground: false,
            finishShortcut: FinishShortcutStore.load().focusShortcut,
            allowsManualFinish: false,
            closeSessionResourcesOnFinish: false,
            restorePreviousApplicationOnStop: false
        )
        let lock = FocusLock(spec: spec)
        zeroDriftIdleLock = lock

        Thread.detachNewThread {
            let failureMessage: String?
            do {
                try lock.run()
                failureMessage = nil
            } catch {
                failureMessage = "Zero Drift could not secure this Mac: \(error)"
            }

            Task { @MainActor in
                guard self.zeroDriftIdleLock === lock else { return }
                self.zeroDriftIdleLock = nil

                if let pending = self.pendingZeroDriftStart {
                    self.pendingZeroDriftStart = nil
                    self.start(pending.intention, runtimeEndDate: pending.runtimeEndDate)
                    return
                }

                if let failureMessage {
                    self.zeroDriftEndsAt = nil
                    self.zeroDriftLimitTask?.cancel()
                    self.zeroDriftLimitTask = nil
                    try? self.zeroDriftStore.clear()
                    self.errorMessage = failureMessage
                    return
                }

                self.startZeroDriftIdleLockIfNeeded()
            }
        }
    }

    private func scheduleSessionLimit(for intention: Intention, runtimeEndDate: Date?) {
        sessionLimitTask?.cancel()
        let now = Date()
        let timerEndDate = intention.timerMinutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) }
        let clockEndDate = intention.endTimeDate(after: now)
        let candidates = [timerEndDate, clockEndDate, runtimeEndDate].compactMap { $0 }
        guard let endDate = candidates.min() else {
            activeSessionEndsAt = nil
            sessionLimitTask = nil
            overlayPresenter?.hideSessionTimer()
            return
        }

        let duration = max(0.1, endDate.timeIntervalSince(now))
        activeSessionEndsAt = endDate
        if let activeSessionEndsAt {
            overlayPresenter?.showSessionTimer(
                name: intention.name,
                endsAt: activeSessionEndsAt
            )
        }
        sessionLimitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  self.activeSessionID == intention.id else {
                return
            }
            self.errorMessage = "\(intention.name)'s scheduled session finished."
            self.activeLock?.stop()
        }
    }

    private func beginCooldown(for intention: Intention) {
        guard let minutes = intention.coolDownMinutes else { return }
        do {
            let nextAllowedDate = try cooldownStore.begin(intentionID: intention.id, minutes: minutes)
            cooldownExpirations[intention.id] = nextAllowedDate
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
        guard !intention.isLeisure else { return [] }
        return intention.allowedApps.filter {
            Self.supportedBrowserBundleIdentifiers.contains($0.bundleIdentifier)
        }
    }

    private static let supportedBrowserBundleIdentifiers: Set<String> = [
        "org.mozilla.firefox",
        "com.google.Chrome"
    ]

    func saveSchedules() {
        do {
            try scheduleStore.save(schedules)
        } catch {
            errorMessage = "Could not save schedules: \(error)"
        }
    }

    /// Used by calendar sync when an external linked event updates a local schedule.
    func persistSchedulesFromSync() {
        saveSchedules()
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

    private func matchedIntention(for purpose: String, minimumScore: Double) -> Intention? {
        guard let match = PurposeIntentionMatcher.bestMatch(
            for: purpose,
            in: intentions,
            minimumScore: minimumScore
        ) else {
            return nil
        }
        return intentions.first { $0.id == match.intentionID }
    }

    private func purposeInterpretation(
        _ interpretation: PurposeLiveInterpretation?,
        isCompatibleWith intention: Intention
    ) -> Bool {
        guard let interpretation else { return true }

        let existingApps = Set(intention.allowedApps.map(\.bundleIdentifier))
        let excludedApps = Set(interpretation.excludedAppBundleIdentifiers)
        guard existingApps.isDisjoint(with: excludedApps) else { return false }

        let includedIntentions = Set(interpretation.includedIntentionIDs)
        if !includedIntentions.isEmpty, !includedIntentions.contains(intention.id) {
            return false
        }

        let explicitApps = Set(interpretation.explicitlyIncludedAppBundleIdentifiers)
        guard explicitApps.isSubset(of: existingApps) else { return false }

        if interpretation.limitsAppsToSelection {
            return Set(interpretation.includedAppBundleIdentifiers) == existingApps
        }
        return true
    }

    private func makePurposeIntention(
        from suggestion: AIIntentionSuggestion,
        appsByIdentifier: [String: AllowedApp]
    ) -> Intention? {
        let allowedApps = suggestion.appBundleIdentifiers.compactMap { appsByIdentifier[$0] }
        guard !allowedApps.isEmpty else { return nil }

        let position = GraphPoint.zero
        let allowedWebsites = suggestion.websites.map {
            AllowedWebsite($0.value, browserBundleIdentifier: $0.browserBundleIdentifier)
        }
        let restrictionNodes = suggestion.restrictions.enumerated().map { offset, restriction in
            RestrictionNode(
                kind: restriction.kind,
                position: Self.aiConnectedNodePosition(
                    center: position,
                    index: offset,
                    total: suggestion.restrictions.count,
                    above: true
                ),
                excludedResourceIDs: restriction.resourceIDs,
                durationMinutes: restriction.kind == .timer || restriction.kind == .coolDown
                    ? max(1, restriction.durationMinutes)
                    : nil,
                showsRemainingTime: restriction.kind == .timer || restriction.kind == .coolDown
                    ? true
                    : nil,
                locksSessionUntilTimerEnds: restriction.kind == .timer ? true : nil
            )
        }
        let frictionNodes = suggestion.frictions.enumerated().map { offset, friction in
            FrictionNode(
                friction: friction.friction(intentionName: suggestion.name),
                position: Self.aiConnectedNodePosition(
                    center: position,
                    index: offset,
                    total: suggestion.frictions.count,
                    above: false
                )
            )
        }

        return Intention(
            name: suggestion.name,
            icon: "sparkles",
            colorHex: "#F5F5F7",
            folder: "",
            allowedApps: allowedApps,
            allowedWebsites: allowedWebsites,
            startupActions: [],
            restrictions: .init(),
            graphPosition: position,
            restrictionNodes: restrictionNodes,
            frictionNodes: frictionNodes,
            isLeisure: false
        )
    }

    private func makePurposeSaveCandidate(
        from intention: Intention,
        statedPurpose: String,
        usage: PurposeSessionUsage
    ) -> PurposeSessionSaveCandidate {
        var usedAppIdentifiers = usage.appBundleIdentifiers
        var usedWebsiteResourceIDs = usage.websiteResourceIDs

        if usedAppIdentifiers.isEmpty {
            usedAppIdentifiers = Set(intention.allowedApps.map(\.bundleIdentifier))
        }
        if usedWebsiteResourceIDs.isEmpty {
            usedWebsiteResourceIDs = Set(intention.allowedWebsites.compactMap { website in
                guard let browser = website.browserBundleIdentifier,
                      usedAppIdentifiers.contains(browser) else {
                    return nil
                }
                return website.resourceID
            })
        }

        let usedWebsites = intention.allowedWebsites.filter {
            usedWebsiteResourceIDs.contains($0.resourceID)
        }
        for website in usedWebsites {
            if let browser = website.browserBundleIdentifier {
                usedAppIdentifiers.insert(browser)
            }
        }

        var saved = intention
        saved.allowedApps = intention.allowedApps.filter {
            usedAppIdentifiers.contains($0.bundleIdentifier)
        }
        saved.allowedWebsites = usedWebsites
        return PurposeSessionSaveCandidate(
            intention: saved,
            statedPurpose: statedPurpose
        )
    }

    private func clearPendingPurposeStart() {
        guard let pendingStartIntention,
              purposeTemporaryIntention?.id == pendingStartIntention.id else {
            return
        }
        purposeTemporaryIntention = nil
        purposeStatedPrompt = nil
    }

    private func availableAIPosition(index: Int, occupied: [GraphPoint]) -> GraphPoint {
        let goldenAngle = 2.399963229728653
        for attempt in 0..<180 {
            let step = index + attempt
            let angle = Double(step) * goldenAngle
            let radius = 340 + Double(step / 7) * 185
            let candidate = GraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            let clearOfWelcome = hypot(candidate.x, candidate.y) >= 250
            let clearOfIntentions = occupied.allSatisfy {
                hypot(candidate.x - $0.x, candidate.y - $0.y) >= 270
            }
            if clearOfWelcome && clearOfIntentions {
                return candidate
            }
        }
        return .init(x: Double(index) * 290, y: 620)
    }

    private static func aiConnectedNodePosition(
        center: GraphPoint,
        index: Int,
        total: Int,
        above: Bool
    ) -> GraphPoint {
        let count = max(total, 1)
        let spacing = 150.0
        let centeredOffset = (Double(index) - Double(count - 1) / 2) * spacing
        return .init(
            x: center.x + centeredOffset,
            y: center.y + (above ? -230 : 240)
        )
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

struct PendingEndTimeRequest: Identifiable {
    let id = UUID()
    let intentionID: String
    let intentionName: String
    let suggestedEndDate: Date

    init(intention: Intention, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        intentionID = intention.id
        intentionName = intention.name
        suggestedEndDate = calendar.date(
            bySetting: .second,
            value: 0,
            of: now
        ) ?? now
    }
}
