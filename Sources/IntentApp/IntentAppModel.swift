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
    func showSessionControls(occurrenceID: UUID)
    var isSessionControlsExpanded: Bool { get }
    @discardableResult func collapseSessionControlsIfExpanded() -> Bool
    func toggleSessionControls()
    func hideSessionTimer()
    func showSessionExpiry(occurrenceID: UUID, name: String)
    func hideSessionExpiry()
}

@MainActor
final class IntentAppModel: ObservableObject {
    private static let requireManualFinishKey = "intentRequireManualFinishBeforeSwitching"
    let onboarding = IntentOnboardingCoordinator()

    @Published var intentions: [Intention] = []
    @Published var selectedID: String?
    @Published var activeChecklist: [String] = []
    @Published var completedChecklist: Set<Int> = []
    private var saveSessionOnFinish = false
    private var pendingOnboardingReplacement: (draftID: String, savedID: String)?
    @Published var activeSessionName: String?
    @Published var activeSessionIsLeisure = false
    @Published var activeSessionEndsAt: Date?
    @Published private(set) var activeSessionAbsoluteEndTime: Date?
    @Published private(set) var activeSessionOccurrenceID: UUID?
    @Published var zeroDriftEndsAt: Date?
    @Published var cooldownExpirations: [String: Date] = [:]
    @Published var pendingFriction: PendingFriction?
    @Published var pendingEndTimeRequest: PendingEndTimeRequest?
    @Published var errorMessage: String?
    @Published var installedApps: [InstalledApp] = []
    @Published var alwaysAllowedApps: [AllowedApp] = []
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

    let activityRecorder = ActivityRecordingController()

    weak var overlayPresenter: IntentOverlayPresenting?
    var onWorkspaceChanged: (() -> Void)?

    private(set) var profileDirectory = IntentProfilePaths.guestDirectory()
    private var store = IntentionStore()
    private var scheduleStore = IntentScheduleStore()
    private let alwaysAllowedAppStore = AlwaysAllowedAppStore()
    private let cooldownStore = IntentionCooldownStore()
    private let zeroDriftStore = ZeroDriftStateStore()
    private var hasResetRuntimeOnLaunch = false
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
    private var quickSelectionWindowIDs: [String: Set<UInt32>] = [:]
    private var quickSelectionTabIDs: [String: [Int]]?
    private var quickSelectionBrowserSessionIDs: [String: String] = [:]
    private var quickSelectionIntentionID: String?
    private var quickSelectionOnboardingOrigin: IntentOnboardingStep?
    private var firstIntentionID: String?
    private var quickSelectionMonitor: Task<Void, Never>?

    /// Run an unsaved first intention and offer the usual save sheet only after completion.
    func startFirstIntention(_ intention: Intention) -> Bool {
        guard !hasActiveSession, !isZeroDriftActive, pendingPurposeSessionSave == nil else {
            errorMessage = "Finish the current intention and save or dismiss its result first."
            return false
        }
        errorMessage = nil
        firstIntentionID = intention.id
        quickSelectionTabIDs = nil
        quickSelectionBrowserSessionIDs = [:]
        purposeTemporaryIntention = intention
        purposeStatedPrompt = intention.name
        start(intention)
        if !hasActiveSession {
            firstIntentionID = nil
            purposeTemporaryIntention = nil
            purposeStatedPrompt = nil
        }
        return hasActiveSession
    }

    func startQuickSelection(_ selection: QuickSelection, apps: [AllowedApp], snapshots: [BrowserTabSnapshot], onboardingOrigin: IntentOnboardingStep? = nil) -> Bool {
        guard !hasActiveSession, !isZeroDriftActive, pendingPurposeSessionSave == nil,
              pendingFriction == nil, pendingEndTimeRequest == nil else {
            errorMessage = "Finish the current intention and save or dismiss its result first."
            return false
        }
        do {
            var intention = try selection.makeIntention(apps: apps, snapshots: snapshots)
            let teachingOrigin = onboarding.isTeaching && (onboardingOrigin == .overview || onboardingOrigin == .quickMark) ? onboardingOrigin : nil
            if teachingOrigin != nil {
                let purpose = onboarding.purposeName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !purpose.isEmpty { intention.name = purpose }
            }
            for browser in Set(selection.tabs.map(\.browser)) {
                guard BrowserGuardStateStore(fileURL: BrowserGuardStateStore.fileURL(for: browser)).isEnabled() else {
                    errorMessage = "Turn on Intent Browser Guard before starting a selected-tab intention."
                    return false
                }
                let heartbeat = BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser))
                guard heartbeat.supports(selection.accessMode == .blacklist ? .blacklistSelection : .quickSelection, maxAge: 5),
                      heartbeat.supports(.tabSessionIdentity, maxAge: 5) else {
                    errorMessage = "Update Intent Browser Guard for selected-tab sessions, then try again."
                    return false
                }
                guard let expected = selection.browserSessionIDs[browser], !expected.isEmpty,
                      snapshots.first(where: { $0.browserBundleIdentifier == browser })?.browserSessionID == expected else {
                    errorMessage = "The browser restarted or Browser Guard reloaded. Clear your marks and choose the current tabs again."
                    return false
                }
            }
            errorMessage = nil
            quickSelectionIntentionID = intention.id
            quickSelectionOnboardingOrigin = teachingOrigin
            quickSelectionWindowIDs = selection.windowIDsByApp
            quickSelectionTabIDs = selection.tabIDsByBrowser
            quickSelectionBrowserSessionIDs = selection.browserSessionIDs
            purposeTemporaryIntention = intention
            purposeStatedPrompt = teachingOrigin == nil ? "your Quick Focus selection" : intention.name
            // Deliberately bypass Always Allowed additions: only green selections belong here.
            requestStart(intention)
            let accepted = hasActiveSession || pendingFriction != nil || pendingEndTimeRequest != nil
            if !accepted {
                quickSelectionIntentionID = nil
                quickSelectionOnboardingOrigin = nil
                quickSelectionTabIDs = nil
                quickSelectionBrowserSessionIDs = [:]
                purposeTemporaryIntention = nil
                purposeStatedPrompt = nil
            }
            return accepted
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    private var pendingZeroDriftStart: (intention: Intention, runtimeEndDate: Date?)?
    private var undoStack: [[Intention]] = []
    private var activeMoveUndoKeys: Set<String> = []
    private var scheduleTimer: Timer?
    private var sessionLimitTask: Task<Void, Never>?
    private var sessionExpiryPolicy: SessionExpiryPolicy?
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
        if !activeChecklist.isEmpty && completedChecklist.count < activeChecklist.count { return false }
        guard let intention = activeSessionIntention,
              intention.sessionLocksManualFinish else {
            return true
        }
        // Runtime expiry owns completion; civil-clock changes must not briefly
        // enable a manual finish before the continuous-clock duration expires.
        return sessionExpiryPolicy?.hasDeadline != true && activeSessionEndsAt == nil
    }

    func load() {
        if installedApps.isEmpty {
            installedApps = AppCatalog.load()
        }

        do {
            alwaysAllowedApps = try alwaysAllowedAppStore.load()
        } catch {
            alwaysAllowedApps = [AlwaysAllowedAppStore.finder]
            errorMessage = "Intent could not load always-allowed apps: \(error)"
        }

        do {
            intentions = AlwaysAllowedAppStore.applying(
                alwaysAllowedApps,
                to: try store.load()
            )
            selectedID = selectedID ?? intentions.first?.id
            undoStack.removeAll()
            activeMoveUndoKeys.removeAll()
            do {
                try store.save(intentions)
            } catch {
                errorMessage = "Intentions loaded, but the latest layout could not be saved: \(error)"
            }
        } catch {
            errorMessage = "Could not load intentions: \(error)"
            intentions = []
            selectedID = nil
        }

        do {
            if IntentEnvironment.isQA { schedules = [] }
            else {
            schedules = try scheduleStore.load()
            }
        } catch {
            errorMessage = "Could not load schedules: \(error)"
            schedules = []
        }
        do {
            cooldownExpirations = try cooldownStore.activeCooldowns()
        } catch {
            cooldownExpirations = [:]
        }
        if !hasResetRuntimeOnLaunch {
            hasResetRuntimeOnLaunch = true
            // Restart is recovery, never a reason to re-lock the user's computer.
            emergencyStop(showMessage: false)
            for index in schedules.indices where !IntentEnvironment.isQA {
                if let key = schedules[index].triggerKeyIfDue(at: Date()) {
                    schedules[index].lastTriggeredKey = key
                }
            }
            if !IntentEnvironment.isQA { saveSchedules() }
        }
        if !IntentEnvironment.isQA { startScheduleTimer() }
    }

    func switchProfile(to directory: URL) {
        guard !hasActiveSession else {
            errorMessage = "Finish the active intention before switching accounts."
            return
        }
        profileDirectory = directory
        store = IntentionStore(fileURL: IntentProfilePaths.intentionsURL(in: directory))
        scheduleStore = IntentScheduleStore(fileURL: IntentProfilePaths.schedulesURL(in: directory))
        selectedID = nil
        load()
    }

    func replaceWorkspace(intentions newIntentions: [Intention], schedules newSchedules: [IntentSchedule]) {
        guard !hasActiveSession else { return }
        intentions = AlwaysAllowedAppStore.applying(alwaysAllowedApps, to: newIntentions)
        schedules = newSchedules
        selectedID = intentions.first?.id
        undoStack.removeAll()
        activeMoveUndoKeys.removeAll()
        do {
            try store.save(intentions)
            try scheduleStore.save(schedules)
        } catch {
            errorMessage = "Could not save the synced workspace: \(error)"
        }
    }

    @discardableResult
    func save() -> Bool {
        guard !hasActiveSession else { return false }
        do {
            intentions = AlwaysAllowedAppStore.applying(alwaysAllowedApps, to: intentions)
            let namedIntentions = intentions.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            try store.save(namedIntentions)
            onWorkspaceChanged?()
            return true
        } catch {
            errorMessage = "Could not save intentions: \(error)"
            return false
        }
    }

    func isAlwaysAllowed(_ bundleIdentifier: String) -> Bool {
        alwaysAllowedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    func toggleAlwaysAllowedApp(_ app: AllowedApp) {
        guard !hasActiveSession else { return }
        if isAlwaysAllowed(app.bundleIdentifier) {
            alwaysAllowedApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        } else {
            alwaysAllowedApps.append(app)
            intentions = AlwaysAllowedAppStore.applying(alwaysAllowedApps, to: intentions)
        }

        do {
            try alwaysAllowedAppStore.save(alwaysAllowedApps)
            save()
        } catch {
            errorMessage = "Could not update always-allowed apps: \(error)"
        }
    }

    @discardableResult
    func createIntention(at position: GraphPoint) -> String {
        recordUndoSnapshot()
        let intention = AlwaysAllowedAppStore.applying(alwaysAllowedApps, to: Intention(
            name: "",
            icon: "target",
            colorHex: "#F5F5F7",
            folder: "",
            allowedApps: [],
            allowedWebsites: [],
            startupActions: [],
            restrictions: .init(),
            graphPosition: position
        ))
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

            imported.append(AlwaysAllowedAppStore.applying(alwaysAllowedApps, to: Intention(
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
                isLeisure: suggestion.isLeisure,
                accessMode: suggestion.accessMode
            )))
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
        accessMode: IntentionAccessMode,
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

        if let conflict = liveInterpretation?.conflictingIntentionIDs.first,
           let conflictingIntention = intentions.first(where: { $0.id == conflict }) {
            purposeModeError = "Intent can run one saved intention at a time. Remove *\(conflictingIntention.name) first."
            return
        }

        if let explicitIntentionID = liveInterpretation?.includedIntentionIDs.first,
           let existing = intentions.first(where: { $0.id == explicitIntentionID }) {
            requestStart(existing)
            return
        }

        let availableApps = installedApps.map {
            AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier)
        }
        let includedAppNames = liveInterpretation?.includedAppBundleIdentifiers.compactMap { identifier in
            availableApps.first { $0.bundleIdentifier == identifier }?.name
        } ?? []
        let excludedAppNames = liveInterpretation?.excludedAppBundleIdentifiers.compactMap { identifier in
            availableApps.first { $0.bundleIdentifier == identifier }?.name
        } ?? []
        let includedIntentionNames = liveInterpretation?.includedIntentionIDs.compactMap { id in
            intentions.first { $0.id == id }?.name
        } ?? []
        let includedWebsiteNames = liveInterpretation?.includedWebsites.map(\.name) ?? []
        let excludedWebsiteNames = liveInterpretation?.excludedWebsites.map(\.name) ?? []
        let resourceVerb = accessMode == .blacklist ? "Block" : "Keep"
        let liveResolution = """
        Final live interpretation after applying the person's corrections in order:
        - \(resourceVerb) these apps: \(includedAppNames.isEmpty ? "No app was explicitly resolved" : includedAppNames.joined(separator: ", "))
        - Never include these removed apps: \(excludedAppNames.isEmpty ? "None" : excludedAppNames.joined(separator: ", "))
        - \(resourceVerb) these websites: \(includedWebsiteNames.isEmpty ? "No website was explicitly resolved" : includedWebsiteNames.joined(separator: ", "))
        - Never include these removed websites: \(excludedWebsiteNames.isEmpty ? "None" : excludedWebsiteNames.joined(separator: ", "))
        - Explicitly starred saved intentions: \(includedIntentionNames.isEmpty ? "None" : includedIntentionNames.joined(separator: ", "))
        Later corrections override earlier words. Never re-add an app or website listed as removed.
        """
        let modeInstruction = accessMode == .blacklist
            ? "This is blacklist mode. The mentioned resources are prohibited and everything else stays available. Never infer extra blocked resources."
            : "This is whitelist mode. The selected resources are the only resources available during the session."
        let description = """
        Start one immediate session for this purpose: \(purpose)

        \(modeInstruction) A saved intention may only be reused when the person explicitly prefixed its name with an asterisk; do not infer a saved intention from an unstarred name. Do not add friction, timers, cooldowns, or leisure mode unless the person explicitly requested them.

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
            suggestion.accessMode = accessMode

            if let liveInterpretation {
                let included = liveInterpretation.includedAppBundleIdentifiers
                let excluded = Set(liveInterpretation.excludedAppBundleIdentifiers)
                let hasExplicitIntention = !liveInterpretation.includedIntentionIDs.isEmpty
                let hasExplicitAppSelection = !liveInterpretation.explicitlyIncludedAppBundleIdentifiers.isEmpty
                let hasExplicitAppCorrection = liveInterpretation.usedCorrection
                    && (!liveInterpretation.explicitlyIncludedAppBundleIdentifiers.isEmpty || !excluded.isEmpty)
                if (liveInterpretation.limitsAppsToSelection
                    || hasExplicitAppSelection
                    || hasExplicitAppCorrection
                    || hasExplicitIntention),
                   !included.isEmpty {
                    suggestion.appBundleIdentifiers = included
                } else {
                    for identifier in included where !suggestion.appBundleIdentifiers.contains(identifier) {
                        suggestion.appBundleIdentifiers.append(identifier)
                    }
                }
                suggestion.appBundleIdentifiers.removeAll { excluded.contains($0) }
                suggestion.websites.removeAll { excluded.contains($0.browserBundleIdentifier) }

                let excludedWebsiteValues = Set(liveInterpretation.excludedWebsites.map(\.value))
                let hasExplicitWebsiteSelection = !liveInterpretation.explicitlyIncludedWebsiteValues.isEmpty
                let hasExplicitWebsiteCorrection = liveInterpretation.usedCorrection
                    && (!liveInterpretation.explicitlyIncludedWebsiteValues.isEmpty || !excludedWebsiteValues.isEmpty)
                if liveInterpretation.limitsWebsitesToSelection
                    || hasExplicitWebsiteSelection
                    || hasExplicitWebsiteCorrection
                    || hasExplicitIntention
                    || (hasExplicitAppSelection && liveInterpretation.includedWebsites.isEmpty) {
                    suggestion.websites.removeAll()
                }

                let fallbackBrowser = suggestion.appBundleIdentifiers.first(where: BrowserApplication.isBrowser)
                    ?? included.first(where: BrowserApplication.isBrowser)
                for website in liveInterpretation.includedWebsites {
                    guard let browser = website.browserBundleIdentifier ?? fallbackBrowser,
                          !excluded.contains(browser),
                          availableApps.contains(where: { $0.bundleIdentifier == browser }) else {
                        continue
                    }
                    if !suggestion.appBundleIdentifiers.contains(browser) {
                        suggestion.appBundleIdentifiers.append(browser)
                    }
                    let resolved = AIWebsiteSuggestion(value: website.value, browserBundleIdentifier: browser)
                    if !suggestion.websites.contains(where: {
                        $0.value == resolved.value && $0.browserBundleIdentifier == resolved.browserBundleIdentifier
                    }) {
                        suggestion.websites.append(resolved)
                    }
                }
                suggestion.websites.removeAll { excludedWebsiteValues.contains(AllowedWebsite.normalized($0.value)) }

                if accessMode == .blacklist {
                    suggestion.appBundleIdentifiers = included.filter { !excluded.contains($0) }
                    suggestion.websites = liveInterpretation.includedWebsites.compactMap { website in
                        guard let browser = website.browserBundleIdentifier
                                ?? suggestion.appBundleIdentifiers.first(where: BrowserApplication.isBrowser),
                              suggestion.appBundleIdentifiers.contains(browser),
                              !excludedWebsiteValues.contains(AllowedWebsite.normalized(website.value)) else {
                            return nil
                        }
                        return AIWebsiteSuggestion(value: website.value, browserBundleIdentifier: browser)
                    }
                }
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
        guard !hasActiveSession, let candidate = pendingPurposeSessionSave?.intention else { return }
        defer { pendingOnboardingReplacement = nil }
        let isOnboardingCandidate = onboarding.lastIntention?.id == candidate.id
        let replacement = isOnboardingCandidate && pendingOnboardingReplacement?.draftID == candidate.id ? pendingOnboardingReplacement : nil
        let existingID = replacement?.savedID ?? (isOnboardingCandidate ? onboarding.state.savedIntentionID : nil)
        let existing = existingID.flatMap { id in intentions.first(where: { $0.id == id }) }
            ?? intentions.first(where: { $0.id == candidate.id })
        let plan = OnboardingSavePlan(candidate: candidate,
            latestPurpose: isOnboardingCandidate ? onboarding.purposeName : nil,
            existing: existing, replaceExisting: replacement != nil,
            insertionPosition: availableAIPosition(index: 0, occupied: intentions.map(\.graphPosition)))
        let intention = plan.intention
        if plan.action == .keepExisting {
            selectedID = intention.id
            pendingPurposeSessionSave = nil
            if isOnboardingCandidate { onboarding.record(.saved, savedIntentionID: intention.id) }
            return
        }

        let previousIntentions = intentions
        let previousSelectedID = selectedID
        let previousUndoStack = undoStack
        recordUndoSnapshot()
        let stored = AlwaysAllowedAppStore.applying(alwaysAllowedApps, to: intention)
        if plan.action == .replaceExisting, let index = intentions.firstIndex(where: { $0.id == stored.id }) {
            intentions[index] = stored
        } else { intentions.append(stored) }
        selectedID = intention.id
        guard save() else {
            intentions = previousIntentions
            selectedID = previousSelectedID
            undoStack = previousUndoStack
            return
        }
        pendingPurposeSessionSave = nil
        if isOnboardingCandidate {
            onboarding.retainSavedIntention(stored)
            onboarding.record(.saved, savedIntentionID: intention.id)
        }
    }

    /// Uses the normal finish-and-save path; accepting the button is not proof
    /// of saving. Only the successful persistence path records that evidence.
    @discardableResult
    func saveOnboardingIntention(replaceExisting: Bool = false) -> Bool {
        guard let intention = onboarding.lastIntention else { return false }
        let existingID = onboarding.state.savedIntentionID.flatMap { id in intentions.contains(where: { $0.id == id }) ? id : nil }
        if let savedID = existingID, !replaceExisting {
            selectedID = savedID
            onboarding.record(.saved, savedIntentionID: savedID)
            return true
        }
        if hasActiveSession {
            guard activeSessionID == intention.id, activeSessionCanFinishManually else { return false }
            endAndSaveActiveSession()
            if replaceExisting, let existingID { pendingOnboardingReplacement = (intention.id, existingID) }
            return true
        }
        guard pendingPurposeSessionSave == nil || pendingPurposeSessionSave?.intention.id == intention.id else { return false }
        pendingOnboardingReplacement = replaceExisting ? existingID.map { (intention.id, $0) } : nil
        pendingPurposeSessionSave = PurposeSessionSaveCandidate(intention: intention, statedPurpose: intention.name)
        savePurposeSessionCandidate()
        return pendingPurposeSessionSave == nil && intentions.contains(where: { $0.id == (existingID ?? intention.id) })
    }

    func discardPurposeSessionCandidate() {
        guard let intentionID = pendingPurposeSessionSave?.intention.id else { return }
        pendingOnboardingReplacement = nil
        try? cooldownStore.clear(intentionID: intentionID)
        cooldownExpirations.removeValue(forKey: intentionID)
        if selectedID == intentionID {
            selectedID = intentions.first?.id
        }
        pendingPurposeSessionSave = nil
    }

    @discardableResult
    func addDraftIntention(_ draft: Intention, at position: GraphPoint) -> String? {
        var imported = AlwaysAllowedAppStore.applying(alwaysAllowedApps, to: draft)
        guard !hasActiveSession,
              !imported.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !imported.allowedApps.isEmpty else {
            return nil
        }

        let deltaX = position.x - imported.graphPosition.x
        let deltaY = position.y - imported.graphPosition.y
        imported.id = UUID().uuidString
        imported.graphPosition = position
        imported.restrictionNodes = imported.restrictionNodes.map { node in
            var moved = node
            moved.id = UUID().uuidString
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }
        imported.frictionNodes = imported.frictionNodes.map { node in
            var moved = node
            moved.id = UUID().uuidString
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }

        recordUndoSnapshot()
        imported = AlwaysAllowedAppStore.applying(alwaysAllowedApps, to: imported)
        intentions.append(imported)
        selectedID = imported.id
        save()
        return imported.id
    }

    @discardableResult
    func replaceIntention(id: String, with draft: Intention) -> Bool {
        let normalizedDraft = AlwaysAllowedAppStore.applying(alwaysAllowedApps, to: draft)
        guard !hasActiveSession,
              !normalizedDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !normalizedDraft.allowedApps.isEmpty,
              let index = intentions.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let existing = intentions[index]
        let deltaX = existing.graphPosition.x - normalizedDraft.graphPosition.x
        let deltaY = existing.graphPosition.y - normalizedDraft.graphPosition.y
        var updated = normalizedDraft
        updated.id = existing.id
        updated.graphPosition = existing.graphPosition
        updated.restrictionNodes = normalizedDraft.restrictionNodes.map { node in
            var moved = node
            moved.id = UUID().uuidString
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }
        updated.frictionNodes = normalizedDraft.frictionNodes.map { node in
            var moved = node
            moved.id = UUID().uuidString
            moved.position = .init(x: node.position.x + deltaX, y: node.position.y + deltaY)
            return moved
        }

        recordUndoSnapshot()
        intentions[index] = AlwaysAllowedAppStore.applying(alwaysAllowedApps, to: updated)
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

    func requestStart(_ requestedIntention: Intention) {
        let intention = AlwaysAllowedAppStore.applying(alwaysAllowedApps, to: requestedIntention)
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
            errorMessage = intention.accessMode == .blacklist
                ? "Add at least one app or browser website to block before starting this intention."
                : "Add at least one allowed app before starting this intention."
            return
        }
        let unsupportedBrowsers = intention.isLeisure ? [] : intention.allowedApps.filter {
            let requiresWebsiteGuard = intention.accessMode == .whitelist
                || !intention.websites(for: $0.bundleIdentifier).isEmpty
            return $0.isBrowser && !Self.supportedBrowserBundleIdentifiers.contains($0.bundleIdentifier)
                && requiresWebsiteGuard
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
        remainingFrictions = intention.orderedFrictionNodes.filter { if case .taskChecklist = $0.friction { return false }; return true }

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

    func toggleSessionControls() { overlayPresenter?.toggleSessionControls() }

    var hasEligibleSessionControls: Bool { hasActiveSession && (activeSessionEndsAt != nil || !activeChecklist.isEmpty) }
    var isSessionControlsExpanded: Bool { overlayPresenter?.isSessionControlsExpanded == true }
    @discardableResult
    func collapseSessionControlsIfExpanded() -> Bool { overlayPresenter?.collapseSessionControlsIfExpanded() ?? false }

    func setTaskCompleted(_ index: Int, completed: Bool) {
        guard hasActiveSession, activeChecklist.indices.contains(index) else { return }
        if completed { completedChecklist.insert(index) } else { completedChecklist.remove(index) }
        if !activeChecklist.isEmpty && completedChecklist.count == activeChecklist.count { activeLock?.stop() }
    }

    func endAndSaveActiveSession() {
        guard hasActiveSession, activeSessionCanFinishManually else { return }
        pendingOnboardingReplacement = nil
        saveSessionOnFinish = true
        endActiveSession()
    }

    func endActiveSession() {
        sessionSwitchWarning = nil
        guard activeSessionCanFinishManually else {
            if !activeChecklist.isEmpty { errorMessage = "Check off your tasks to finish this intention." }
            else if let activeSessionEndsAt {
                errorMessage = "This intention is locked for another \(Self.durationText(until: activeSessionEndsAt))."
            }
            return
        }
        activeLock?.stop()
    }

    func emergencyStop(showMessage: Bool = true) {
        pendingOnboardingReplacement = nil
        sessionExpiryPolicy?.cancel()
        sessionLimitTask?.cancel()
        overlayPresenter?.hideSessionExpiry()
        cancelEndTimeSelection()
        zeroDriftEndsAt = nil
        zeroDriftLimitTask?.cancel()
        zeroDriftLimitTask = nil
        pendingZeroDriftStart = nil
        pendingReplacementIntention = nil
        zeroDriftIdleLock?.stopForSafety()
        activeLock?.stopForSafety()
        try? zeroDriftStore.clear()
        try? browserRulesStore.clear()
        if showMessage {
            errorMessage = "Safety stop: all active restrictions have been released."
            showOverlay()
        }
    }

    func refreshFinishShortcut() {
        let shortcut = FinishShortcutStore.load().focusShortcut
        activeLock?.updateFinishShortcut(shortcut)
        zeroDriftIdleLock?.updateFinishShortcut(shortcut)
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
        if quickSelectionIntentionID == intention.id, !hasActiveSession,
           pendingZeroDriftStart?.intention.id != intention.id {
            quickSelectionIntentionID = nil
            quickSelectionOnboardingOrigin = nil
            quickSelectionTabIDs = nil
            quickSelectionBrowserSessionIDs = [:]
            purposeTemporaryIntention = nil
            purposeStatedPrompt = nil
        }
    }

    private func start(_ intention: Intention, runtimeEndDate: Date? = nil) {
        guard !intention.selectionRequiresTabReselection || quickSelectionIntentionID == intention.id else {
            errorMessage = "This intention used specific browser tabs. Open ` and choose the current tabs before running it again."
            return
        }
        // Frictions may take time. Revalidate exact tabs before enabling any lock.
        if quickSelectionIntentionID == intention.id, let tabIDs = quickSelectionTabIDs {
            for (browser, ids) in tabIDs {
                let heartbeat = BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser))
                guard heartbeat.supports(.tabSessionIdentity, maxAge: 5),
                      heartbeat.supports(intention.accessMode == .blacklist ? .blacklistSelection : .quickSelection, maxAge: 5),
                      let snapshot = BrowserTabSnapshotStore(browserBundleIdentifier: browser).load(),
                      let expected = quickSelectionBrowserSessionIDs[browser], !expected.isEmpty,
                      snapshot.browserSessionID == expected,
                      ids.allSatisfy({ id in (snapshot.allTabs ?? snapshot.tabs).contains { tab in
                          tab.id == id
                      } }) else {
                    errorMessage = "A selected tab changed while you were getting ready. Reopen ` and choose your tabs again."
                    return
                }
            }
        }
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
            if !heartbeatStore.supports(.singleStartupLaunch, maxAge: 5) {
                let installedVersion = heartbeatStore.heartbeat()?.extensionVersion
                    .map { " \($0)" } ?? ""
                errorMessage = "\(browser.name) is using an outdated Intent Browser Guard\(installedVersion). Update or reload Browser Guard before starting this intention."
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
        let browserGuards = requiredBrowserGuards(for: intention)
        let websitesByBrowser = Dictionary(uniqueKeysWithValues: browserGuards.map { browser in
            let websites = intention.websites(for: browser.bundleIdentifier).map(\.value)
            return (
                browser.bundleIdentifier,
                websites.isEmpty && intention.accessMode == .whitelist ? ["intent.invalid"] : websites
            )
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
        let rules = intention.isLeisure || browserGuards.isEmpty ? nil : ActiveBrowserRules(
            active: true,
            accessMode: intention.accessMode,
            // A non-matching sentinel keeps already-installed Browser Guard 0.1.3 builds strict
            // when Firefox is allowed but the intention has no website spikes.
            allowedWebsites: firefoxWebsites,
            allowedWebsitesByBrowser: websitesByBrowser,
            startupWebsitesByBrowser: startupWebsitesByBrowser,
            startupSessionID: UUID().uuidString,
            selectedTabIDsByBrowser: quickSelectionIntentionID == intention.id ? quickSelectionTabIDs : nil,
            selectedBrowserSessionIDsByBrowser: quickSelectionIntentionID == intention.id ? quickSelectionBrowserSessionIDs : nil,
            blockTabSwitching: true,
            blockNavigation: true,
            blockNewTabs: false,
            allowGoogleSearchTabs: intention.accessMode == .whitelist && intention.browserSearchesAllowed
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
        var lockSpec = rules == nil ? spec : spec.deferringBrowserWebsiteStartupToGuard()
        if quickSelectionIntentionID == intention.id { lockSpec.selectedWindowIDsByApp = quickSelectionWindowIDs }
        let lock = FocusLock(spec: lockSpec)
        pendingOnboardingReplacement = nil
        activeLock = lock
        activeSessionID = intention.id
        activeSessionOccurrenceID = UUID()
        let occurrence = activeSessionOccurrenceID
        let onboardingOrigin = quickSelectionIntentionID == intention.id ? quickSelectionOnboardingOrigin : nil
        overlayPresenter?.hideSessionExpiry()
        activeSessionIntention = intention
        activeSessionName = intention.name
        activeSessionIsLeisure = intention.isLeisure
        if quickSelectionIntentionID == intention.id, !(quickSelectionTabIDs ?? [:]).isEmpty || !quickSelectionWindowIDs.isEmpty {
            let tabIDs = quickSelectionTabIDs ?? [:]
            let browserSessionIDs = quickSelectionBrowserSessionIDs
            let windowIDs = Set(quickSelectionWindowIDs.values.flatMap { $0 })
            quickSelectionMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self, self.activeSessionID == intention.id else { return }
                    if !windowIDs.isEmpty, !windowIDs.isSubset(of: Set(WorkspaceWindow.list(onScreen: false).map(\.id))) {
                        self.activeLock?.stop()
                        self.errorMessage = "A marked window closed, so the intention ended safely."
                        return
                    }
                    for (browser, selected) in tabIDs {
                        let heartbeat = BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser))
                        guard heartbeat.supports(intention.accessMode == .blacklist ? .blacklistSelection : .quickSelection, maxAge: 5),
                              heartbeat.supports(.tabSessionIdentity, maxAge: 5),
                              BrowserGuardStateStore(fileURL: BrowserGuardStateStore.fileURL(for: browser)).isEnabled() else {
                            // Safety failures must release even a user-locked timer.
                            self.activeLock?.stop()
                            self.errorMessage = "The selected-tab intention stopped because Browser Guard disconnected or was turned off."
                            self.showOverlay()
                            return
                        }
                        guard let snapshot = BrowserTabSnapshotStore(browserBundleIdentifier: browser).load(),
                              let expected = browserSessionIDs[browser], !expected.isEmpty,
                              snapshot.browserSessionID == expected else {
                            self.activeLock?.stopForSafety()
                            self.errorMessage = "The browser restarted or Browser Guard reloaded, so this intention stopped safely. Choose your current tabs again."
                            return
                        }
                        if snapshot.updatedAt > Date().addingTimeInterval(-3),
                           !(snapshot.allTabs ?? snapshot.tabs).contains(where: { selected.contains($0.id) }) {
                            self.errorMessage = "Quick Focus finished because its selected browser tabs were closed."
                            self.activeLock?.stop()
                            return
                        }
                    }
                }
            }
        }
        if purposeTemporaryIntention?.id == intention.id {
            let tracker = PurposeSessionUsageTracker(intention: intention)
            purposeUsageTracker = tracker
            tracker.start()
        }
        saveSessionOnFinish = false
        activeChecklist = intention.orderedFrictionNodes.flatMap { node -> [String] in
            if case .taskChecklist(let tasks) = node.friction { return tasks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
            return []
        }
        completedChecklist = []
        scheduleSessionLimit(for: intention, runtimeEndDate: runtimeEndDate)
        if let occurrence = activeSessionOccurrenceID, hasEligibleSessionControls {
            overlayPresenter?.showSessionControls(occurrenceID: occurrence)
        } else { overlayPresenter?.hideSessionTimer() }
        overlayPresenter?.hideOverlay(animated: true)

        Thread.detachNewThread {
            let renewalTimer: DispatchSourceTimer?
            let renewalQueue: DispatchQueue?
            if let rules {
                let queue = DispatchQueue(
                    label: "dev.loganmondi.intent.browser-rules.\(UUID().uuidString)",
                    qos: .utility
                )
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 2, repeating: 2)
                timer.setEventHandler {
                    guard !lock.isStopRequested else { return }
                    try? ActiveBrowserRulesStore().write(rules.refreshed())
                    if lock.isStopRequested { try? ActiveBrowserRulesStore().clear() }
                }
                timer.resume()
                renewalTimer = timer
                renewalQueue = queue
            } else {
                renewalTimer = nil
                renewalQueue = nil
            }

            let failureMessage: String?
            do {
                try lock.run(onReady: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeSessionOccurrenceID == occurrence else { return }
                        if let onboardingOrigin {
                            self.onboarding.capture(intention)
                            self.onboarding.record(onboardingOrigin == .overview ? .overviewRun : .quickMarkRun)
                        }
                        if self.onboarding.state.savedIntentionID == intention.id {
                            self.onboarding.record(.reused)
                        }
                    }
                })
                failureMessage = nil
            } catch {
                failureMessage = "Could not start session: \(error)"
            }

            renewalTimer?.cancel()
            renewalQueue?.sync {}
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
                self.sessionExpiryPolicy?.cancel()
                self.sessionExpiryPolicy = nil
                self.activeSessionEndsAt = nil
                self.activeSessionAbsoluteEndTime = nil
                self.activeSessionOccurrenceID = nil
                self.overlayPresenter?.hideSessionTimer()
                if lock.didStopForSafety {
                    self.emergencyStop()
                } else if failureMessage == nil {
                    self.beginCooldown(for: intention)
                } else {
                    self.emergencyStop(showMessage: false)
                    self.errorMessage = failureMessage
                }
                self.activeLock = nil
                self.quickSelectionMonitor?.cancel()
                self.quickSelectionMonitor = nil
                self.activeSessionID = nil
                self.activeSessionIntention = nil
                self.activeSessionName = nil
                self.activeSessionIsLeisure = false
                if failureMessage == nil,
                   wasPurposeSession,
                   self.saveSessionOnFinish,
                   let purposeUsage,
                   let statedPurpose {
                    self.pendingPurposeSessionSave = (self.quickSelectionIntentionID == intention.id || self.firstIntentionID == intention.id)
                        ? PurposeSessionSaveCandidate(intention: intention, statedPurpose: statedPurpose)
                        : self.makePurposeSaveCandidate(
                        from: intention,
                        statedPurpose: statedPurpose,
                        usage: purposeUsage
                    )
                }
                if self.saveSessionOnFinish, self.pendingPurposeSessionSave != nil { self.savePurposeSessionCandidate() }
                if wasPurposeSession {
                    self.firstIntentionID = nil
                    self.quickSelectionIntentionID = nil
                    self.quickSelectionOnboardingOrigin = nil
                    self.quickSelectionTabIDs = nil
                    self.quickSelectionBrowserSessionIDs = [:]
                    self.purposeTemporaryIntention = nil
                    self.purposeStatedPrompt = nil
                }
                self.activeChecklist = []
                self.completedChecklist = []
                if self.saveSessionOnFinish || failureMessage != nil || lock.didStopForSafety { self.overlayPresenter?.showOverlay(animated: true) }
                self.saveSessionOnFinish = false
                if let replacement, !lock.didStopForSafety, failureMessage == nil {
                    self.requestStart(replacement)
                } else {
                    self.startZeroDriftIdleLockIfNeeded()
                }
            }
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

                if lock.didStopForSafety {
                    self.emergencyStop()
                    return
                }

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
        sessionExpiryPolicy?.cancel()
        let now = Date()
        guard let occurrence = activeSessionOccurrenceID else { return }
        let absoluteEnd = [intention.endTimeDate(after: now), runtimeEndDate].compactMap { $0 }.min()
        let policy = SessionExpiryPolicy(occurrenceID: occurrence,
            duration: intention.timerMinutes.map { TimeInterval($0) * 60 }, absoluteEnd: absoluteEnd)
        sessionExpiryPolicy = policy
        activeSessionAbsoluteEndTime = absoluteEnd
        guard let remaining = policy.remaining(elapsed: 0, now: now) else {
            activeSessionEndsAt = nil
            sessionLimitTask = nil
            return
        }
        activeSessionEndsAt = now.addingTimeInterval(remaining)
        let clock = ContinuousClock()
        let started = clock.now
        sessionLimitTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeSessionOccurrenceID == occurrence,
                      let lock = self.activeLock, !lock.isStopRequested else { return }
                let components = started.duration(to: clock.now).components
                let elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
                let wallNow = Date()
                if self.sessionExpiryPolicy?.expire(elapsed: elapsed, now: wallNow) != nil {
                    self.overlayPresenter?.showSessionExpiry(occurrenceID: occurrence, name: intention.name)
                    lock.stopForExpiry()
                    return
                }
                if let remaining = self.sessionExpiryPolicy?.remaining(elapsed: elapsed, now: wallNow) {
                    // Updating countdown data must never reinstall or reopen the panel.
                    let projectedEnd = wallNow.addingTimeInterval(remaining)
                    if self.activeSessionEndsAt.map({ abs($0.timeIntervalSince(projectedEnd)) > 0.25 }) ?? true {
                        self.activeSessionEndsAt = projectedEnd
                    }
                }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
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
                && (intention.accessMode == .whitelist
                    || !intention.websites(for: $0.bundleIdentifier).isEmpty
                    || intention.selectionBrowserBundleIdentifiers.contains($0.bundleIdentifier))
        }
    }

    private static let supportedBrowserBundleIdentifiers: Set<String> = [
        "org.mozilla.firefox",
        "com.google.Chrome"
    ]

    func saveSchedules() {
        do {
            try scheduleStore.save(schedules)
            onWorkspaceChanged?()
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

        let existingWebsiteValues = Set(intention.allowedWebsites.map { AllowedWebsite.normalized($0.value) })
        let excludedWebsiteValues = Set(interpretation.excludedWebsites.map(\.value))
        guard existingWebsiteValues.isDisjoint(with: excludedWebsiteValues) else { return false }

        let explicitWebsiteValues = Set(interpretation.explicitlyIncludedWebsiteValues)
        guard explicitWebsiteValues.isSubset(of: existingWebsiteValues) else { return false }

        if interpretation.limitsAppsToSelection {
            guard Set(interpretation.includedAppBundleIdentifiers) == existingApps else { return false }
        }
        if interpretation.limitsWebsitesToSelection {
            guard Set(interpretation.includedWebsites.map(\.value)) == existingWebsiteValues else { return false }
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
            isLeisure: false,
            accessMode: suggestion.accessMode
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
        quickSelectionIntentionID = nil
        quickSelectionTabIDs = nil
        quickSelectionBrowserSessionIDs = [:]
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
