import AppKit
import Combine
import IntentCore

/// One resumable guide over the real application, never a second input router.
@MainActor
final class IntentOnboardingCoordinator: ObservableObject {
    private static let stateKey = "intentOnboardingV2"
    private static let draftKey = "intentOnboardingRunV2"
    static let deferredKey = "intentOnboardingDeferredV2"
    @Published var state: IntentOnboardingState
    @Published var isPresented = false
    @Published var selectionVisible = false
    @Published var canvasRequest: UUID?
    @Published private(set) var setupBrowser: String?
    @Published private(set) var lastIntention: Intention?
    private var timer: Timer?
    private var purposeReturnStep: IntentOnboardingStep?
    private let defaults: UserDefaults
    private let clock = ContinuousClock()
    private var clockOrigin: ContinuousClock.Instant
    private var dateOrigin: Date

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clockOrigin = ContinuousClock().now
        dateOrigin = Date()
        state = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(IntentOnboardingState.self, from: $0) } ?? .init()
        state.resumeAfterRelaunch(now: dateOrigin)
        purposeReturnStep = defaults.string(forKey: "intentOnboardingPurposeReturnV2").flatMap(IntentOnboardingStep.init(rawValue:))
        lastIntention = defaults.data(forKey: Self.draftKey).flatMap { try? JSONDecoder().decode(Intention.self, from: $0) }
        // Preserve an unfinished answer from the former guide without importing
        // its tutorial-only resource picker or claiming an action was performed.
        if state.purpose.isEmpty, let data = defaults.data(forKey: "intentFirstIntentionDraftV1"),
           let old = try? JSONDecoder().decode(FirstIntentionDraft.self, from: data) {
            state.purpose = old.name
        }
    }

    var isTeaching: Bool { isPresented && state.startedAt != nil && state.completedAt == nil }
    var purposeName: String { state.defaultName }
    private var now: Date {
        let elapsed = clockOrigin.duration(to: clock.now).components
        return dateOrigin.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    func present(replay: Bool = false) {
        if replay || state.completedAt != nil { state.replay(); lastIntention = nil; purposeReturnStep = nil }
        if state.startedAt != nil {
            state.begin(now: now)
            IntentRuntime.shared.beginOnboardingSelectionScope()
        }
        state.forgetSavedIntention(ifMissingFrom: Set(IntentRuntime.shared.model.intentions.map(\.id)))
        isPresented = true
        defaults.set(false, forKey: Self.deferredKey)
        tick()
        timer?.invalidate()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func begin() {
        if IntentRuntime.shared.accountManager.requiresFirstRunChoice { IntentRuntime.shared.accountManager.continueAsGuest() }
        state.begin(now: now)
        IntentRuntime.shared.beginOnboardingSelectionScope()
        persist()
    }
    func setPurpose(_ value: String) { state.purpose = value; persist() }
    func editPurpose() { purposeReturnStep = state.step; state.move(to: .purpose, now: now); persist() }
    func submitPurpose() {
        guard state.submitPurpose(now: now) else { return }
        if let returnStep = purposeReturnStep { state.move(to: returnStep, now: now); purposeReturnStep = nil }
        persist()
    }
    func move(to step: IntentOnboardingStep) { setupBrowser = nil; state.move(to: step, now: now); persist() }
    func skip() { setupBrowser = nil; state.skipCurrent(now: now); persist() }
    func connectBrowser(_ browser: String) { setupBrowser = browser; setSetupInProgress(true); IntentBrowserSetup.open(browser) }
    func continueWithAppWindows() { setupBrowser = nil; setSetupInProgress(false) }
    func setSetupInProgress(_ required: Bool) { state.setSetupInProgress(required, now: now); persist() }
    func capture(_ intention: Intention) {
        guard isTeaching else { return }
        lastIntention = intention
        persist()
    }
    /// This is storage bookkeeping, not tutorial evidence. An explicitly chosen
    /// finish-and-save can persist after the user closes the guide.
    func retainSavedIntention(_ intention: Intention) {
        state.forgetSavedIntention(ifMissingFrom: Set(IntentRuntime.shared.model.intentions.map(\.id)))
        _ = state.retainSavedIntentionID(intention.id)
        guard state.savedIntentionID == intention.id else { return }
        lastIntention = intention
        persist()
    }
    func record(_ evidence: IntentOnboardingEvidence, savedIntentionID: String? = nil) {
        guard isTeaching else { return }
        if evidence == .saved { state.forgetSavedIntention(ifMissingFrom: Set(IntentRuntime.shared.model.intentions.map(\.id))) }
        state.record(evidence, now: now, savedIntentionID: savedIntentionID)
        persist()
    }
    func showSavedOnCanvas() {
        guard let id = state.savedIntentionID else { return }
        IntentRuntime.shared.model.selectedID = id
        IntentRuntime.shared.model.showOverlay()
        canvasRequest = UUID()
        move(to: .ready)
    }
    func exit() {
        guard isPresented else { return }
        state.exit(now: now)
        setupBrowser = nil
        isPresented = false
        timer?.invalidate(); timer = nil
        defaults.set(true, forKey: Self.deferredKey)
        IntentRuntime.shared.endOnboardingSelectionScope()
        persist()
    }
    func finish() {
        guard state.finish(now: now) else { return }
        purposeReturnStep = nil; setupBrowser = nil
        isPresented = false
        timer?.invalidate(); timer = nil
        defaults.set(true, forKey: "intentDidCompleteOnboarding")
        defaults.set(false, forKey: Self.deferredKey)
        IntentRuntime.shared.endOnboardingSelectionScope()
        persist()
    }
    func replay() {
        guard !IntentRuntime.shared.model.hasActiveSession else { return }
        IntentRuntime.shared.endOnboardingSelectionScope()
        state.replay(); lastIntention = nil; purposeReturnStep = nil; setupBrowser = nil; persist()
    }
    private func tick() {
        state.observe(now: now)
        persist()
    }
    private func persist() {
        if let purposeReturnStep { defaults.set(purposeReturnStep.rawValue, forKey: "intentOnboardingPurposeReturnV2") }
        else { defaults.removeObject(forKey: "intentOnboardingPurposeReturnV2") }
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
        if let lastIntention, let data = try? JSONEncoder().encode(lastIntention) { defaults.set(data, forKey: Self.draftKey) }
        else { defaults.removeObject(forKey: Self.draftKey) }
        // Local aggregate values only. The draft above is not analytics.
        if let data = try? JSONEncoder().encode(state.measurement) { defaults.set(data, forKey: "intentOnboardingMeasurementsV2") }
    }
    deinit { timer?.invalidate() }
}
