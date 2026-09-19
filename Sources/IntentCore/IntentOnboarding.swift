import Foundation

public enum IntentOnboardingStep: String, Codable, CaseIterable, Hashable {
    case welcome, purpose, overview, quickMark, save, ready

    public var skill: IntentOnboardingSkill? {
        switch self {
        case .overview: .overview
        case .quickMark: .quickMark
        case .save: .save
        default: nil
        }
    }

    public var next: Self? {
        guard let index = Self.allCases.firstIndex(of: self), index + 1 < Self.allCases.count else { return nil }
        return Self.allCases[index + 1]
    }
}

public enum IntentOnboardingSkill: String, Codable, CaseIterable, Hashable {
    case overview, quickMark, save
}

/// Evidence comes from the existing product handlers, never from tutorial navigation.
public enum IntentOnboardingEvidence: String, Codable, CaseIterable, Hashable {
    case overviewShortcut, overviewOpened, overviewRun
    case quickMarkShortcut, quickMarkChanged, quickMarkRun
    case saved, reused
}

public struct IntentOnboardingStepMeasurement: Codable, Equatable {
    public let step: IntentOnboardingStep
    public let visits: Int
    public let activeSeconds: TimeInterval
    public let abandonments: Int
}

/// Safe to export to local diagnostics: deliberately has no purpose, saved ID, URL or title.
public struct IntentOnboardingMeasurement: Codable, Equatable {
    public let fullExperienceSeconds: TimeInterval
    public let coreTutorialSeconds: TimeInterval
    public let requiredSetupSeconds: TimeInterval
    public let timeToFirstRunSeconds: TimeInterval?
    public let completed: Bool
    public let demonstrated: Set<IntentOnboardingSkill>
    public let skipped: Set<IntentOnboardingSkill>
    public let evidence: Set<IntentOnboardingEvidence>
    public let steps: [IntentOnboardingStepMeasurement]
}

/// Resumable tutorial state, separate from the running intention and its timer.
/// Persist this locally; only `measurement` is suitable for diagnostic output.
public struct IntentOnboardingState: Codable, Equatable {
    public static let suggestedDuration: TimeInterval = 180

    /// Keep the original text intact, including Unicode and internal whitespace.
    public var purpose: String
    public private(set) var step: IntentOnboardingStep = .welcome
    public private(set) var startedAt: Date?
    public private(set) var completedAt: Date?
    public private(set) var firstRunAt: Date?
    public private(set) var savedIntentionID: String?
    public private(set) var demonstrated: Set<IntentOnboardingSkill> = []
    public private(set) var skipped: Set<IntentOnboardingSkill> = []
    public private(set) var evidence: Set<IntentOnboardingEvidence> = []
    public private(set) var isActive = false
    public private(set) var isSetupInProgress = false
    public private(set) var observedElapsedSeconds: TimeInterval = 0

    private var coreTutorialSeconds: TimeInterval = 0
    private var requiredSetupSeconds: TimeInterval = 0
    private var firstRunElapsedSeconds: TimeInterval?
    private var stepVisits: [IntentOnboardingStep: Int] = [:]
    private var stepActiveSeconds: [IntentOnboardingStep: TimeInterval] = [:]
    private var stepAbandonments: [IntentOnboardingStep: Int] = [:]

    public init(purpose: String = "", savedIntentionID: String? = nil) {
        self.purpose = purpose
        self.savedIntentionID = Self.nonemptyID(savedIntentionID)
    }

    public var defaultName: String {
        purpose.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasStarted: Bool { startedAt != nil }
    public var isComplete: Bool { completedAt != nil }

    public var measurement: IntentOnboardingMeasurement {
        IntentOnboardingMeasurement(
            fullExperienceSeconds: observedElapsedSeconds,
            coreTutorialSeconds: coreTutorialSeconds,
            requiredSetupSeconds: requiredSetupSeconds,
            timeToFirstRunSeconds: firstRunElapsedSeconds,
            completed: isComplete,
            demonstrated: demonstrated,
            skipped: skipped,
            evidence: evidence,
            steps: IntentOnboardingStep.allCases.map {
                IntentOnboardingStepMeasurement(step: $0, visits: stepVisits[$0, default: 0],
                                                activeSeconds: stepActiveSeconds[$0, default: 0],
                                                abandonments: stepAbandonments[$0, default: 0])
            }
        )
    }

    /// The initial button starts the clock. Calling this again resumes the same attempt.
    public mutating func begin(now: Date = Date()) {
        guard !isComplete else { return }
        if startedAt == nil {
            startedAt = now
            step = .purpose
        } else {
            observe(now: now)
        }
        if !isActive {
            isActive = true
            stepVisits[step, default: 0] += 1
        }
    }

    /// Call from a model tick, not a SwiftUI body. A caller may supply a Date derived
    /// from a monotonic clock. Persisting the high-water mark also handles clock rollback.
    public mutating func observe(now: Date = Date()) {
        guard let startedAt, !isComplete else { return }
        let candidate = now.timeIntervalSince(startedAt)
        guard candidate.isFinite else { return }
        let elapsed = max(observedElapsedSeconds, max(0, candidate))
        let delta = elapsed - observedElapsedSeconds
        observedElapsedSeconds = elapsed
        guard isActive, delta > 0 else { return }
        stepActiveSeconds[step, default: 0] += delta
        if isSetupInProgress {
            requiredSetupSeconds += delta
        } else {
            coreTutorialSeconds += delta
        }
    }

    @discardableResult
    public mutating func submitPurpose(now: Date = Date()) -> Bool {
        guard hasStarted, !isComplete, !defaultName.isEmpty else { return false }
        observe(now: now)
        if step == .purpose || step == .welcome { move(to: .overview, now: now) }
        return true
    }

    /// Navigation never implies that a skill was demonstrated.
    public mutating func move(to nextStep: IntentOnboardingStep, now: Date = Date()) {
        guard hasStarted, !isComplete else { return }
        observe(now: now)
        guard step != nextStep else { return }
        step = nextStep
        if isActive { stepVisits[step, default: 0] += 1 }
    }

    @discardableResult
    public mutating func skipCurrent(now: Date = Date()) -> Bool {
        guard hasStarted, !isComplete, let skill = step.skill, let next = step.next else { return false }
        if !demonstrated.contains(skill) { skipped.insert(skill) }
        move(to: next, now: now)
        return true
    }

    /// Repeated delivery of an event is idempotent. An existing saved ID is pinned
    /// through replay so retrying onboarding cannot create a second saved intention.
    @discardableResult
    public mutating func record(_ event: IntentOnboardingEvidence, now: Date = Date(),
                                savedIntentionID proposedID: String? = nil) -> Bool {
        guard hasStarted, !isComplete, isActive else { return false }
        observe(now: now)
        if event == .saved || event == .reused {
            let candidate = Self.nonemptyID(proposedID) ?? savedIntentionID
            guard let candidate else { return false }
            if let savedIntentionID, savedIntentionID != candidate { return false }
            // Reuse must refer to an intention actually saved in this or a previous attempt.
            if event == .reused, savedIntentionID == nil { return false }
            savedIntentionID = candidate
        }
        let inserted = evidence.insert(event).inserted
        if (event == .overviewRun || event == .quickMarkRun), firstRunAt == nil {
            firstRunAt = effectiveDate
            firstRunElapsedSeconds = observedElapsedSeconds
        }
        updateDemonstratedSkills()
        return inserted
    }

    /// Required setup is counted honestly while the visible countdown keeps running.
    public mutating func setSetupInProgress(_ inProgress: Bool, now: Date = Date()) {
        observe(now: now)
        guard !isComplete else { return }
        isSetupInProgress = inProgress
    }

    /// Closing the tutorial does not touch an intention. The full experience clock
    /// continues across absence; active tutorial/setup measurements exclude that gap.
    public mutating func exit(now: Date = Date()) {
        observe(now: now)
        guard hasStarted, !isComplete, isActive else { return }
        stepAbandonments[step, default: 0] += 1
        isActive = false
        isSetupInProgress = false
    }

    /// Call once after loading persisted state at process launch, before presenting.
    /// We cannot know how much of the interval since the last persisted observation
    /// was spent in the tutorial, so only the full experience clock includes it.
    public mutating func resumeAfterRelaunch(now: Date = Date()) {
        if hasStarted, !isComplete, isActive {
            stepAbandonments[step, default: 0] += 1
        }
        isActive = false
        isSetupInProgress = false
        observe(now: now)
    }

    /// Saving may finish after the guide closes. Keep the real stored identity
    /// for replay deduplication without claiming observed practice or changing
    /// the tutorial's timing, progress, or completion state.
    @discardableResult
    public mutating func retainSavedIntentionID(_ id: String) -> Bool {
        guard let candidate = Self.nonemptyID(id),
              savedIntentionID == nil || savedIntentionID == candidate else { return false }
        let changed = savedIntentionID != candidate
        savedIntentionID = candidate
        return changed
    }

    /// Reconcile with the actual saved canvas, without replacing an existing ID.
    /// A deleted intention can be saved again; its earlier save/reuse is no longer
    /// presented as a currently available saved result.
    @discardableResult
    public mutating func forgetSavedIntention(ifMissingFrom existingIDs: Set<String>) -> Bool {
        guard let savedIntentionID, !existingIDs.contains(savedIntentionID) else { return false }
        self.savedIntentionID = nil
        evidence.remove(.saved)
        evidence.remove(.reused)
        demonstrated.remove(.save)
        return true
    }

    /// Completing the flow is distinct from demonstrated mastery; skipped skills remain skipped.
    @discardableResult
    public mutating func finish(now: Date = Date()) -> Bool {
        guard hasStarted, !isComplete, !defaultName.isEmpty else { return false }
        move(to: .ready, now: now)
        completedAt = effectiveDate
        isActive = false
        isSetupInProgress = false
        return true
    }

    /// Replay is a fresh, unstarted attempt. Keep the original answer and saved ID
    /// so the UI can reuse the same saved intention instead of saving a duplicate.
    public mutating func replay(now: Date? = nil) {
        if let now { observe(now: now) }
        self = Self(purpose: purpose, savedIntentionID: savedIntentionID)
    }

    public mutating func remainingSeconds(now: Date = Date()) -> Int {
        observe(now: now)
        return remainingSecondsSnapshot
    }

    public mutating func countdownText(now: Date) -> String {
        observe(now: now)
        return countdownText
    }

    /// Rendering this value is read-only; the model's timer should call `observe(now:)`.
    public var countdownText: String {
        let remaining = remainingSecondsSnapshot
        let magnitude = abs(remaining)
        return "\(remaining < 0 ? "-" : "")\(magnitude / 60):\(String(format: "%02d", magnitude % 60))"
    }

    private var remainingSecondsSnapshot: Int {
        // The cap prevents integer overflow for corrupt or far-future persisted dates.
        let wholeElapsed = Int(min(floor(observedElapsedSeconds), TimeInterval(Int.max / 2)))
        return Int(Self.suggestedDuration) - wholeElapsed
    }

    private var effectiveDate: Date? {
        startedAt?.addingTimeInterval(observedElapsedSeconds)
    }

    private mutating func updateDemonstratedSkills() {
        let overview: Set<IntentOnboardingEvidence> = [.overviewShortcut, .overviewOpened, .overviewRun]
        let quickMark: Set<IntentOnboardingEvidence> = [.quickMarkShortcut, .quickMarkChanged, .quickMarkRun]
        if overview.isSubset(of: evidence) { demonstrated.insert(.overview) }
        if quickMark.isSubset(of: evidence) { demonstrated.insert(.quickMark) }
        if evidence.contains(.saved), savedIntentionID != nil { demonstrated.insert(.save) }
        skipped.subtract(demonstrated)
    }

    private static func nonemptyID(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
