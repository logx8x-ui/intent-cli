import Foundation
import IntentCore

func runOnboardingSpecs() throws {
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    func time(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    var onboarding = IntentOnboardingState()
    try expect(onboarding.step == .welcome && !onboarding.hasStarted, "Onboarding starts at an unstarted welcome screen")
    try expect(onboarding.countdownText == "3:00", "The initial countdown is three minutes")
    try expect(!onboarding.submitPurpose(now: time(0)), "Purpose cannot advance before the initial start action")
    onboarding.begin(now: time(0))
    let justStarted = onboarding
    onboarding.begin(now: time(0))
    try expect(onboarding == justStarted, "Repeated begin delivery is idempotent")
    try expect(onboarding.step == .purpose && onboarding.isActive, "Beginning asks for the real purpose first")
    try expect(!onboarding.skipCurrent(now: time(0)), "The required real-purpose question cannot be silently skipped")
    for blank in ["", "  ", "\n\t", "\u{2003}\u{3000}"] {
        onboarding.purpose = blank
        try expect(!onboarding.submitPurpose(now: time(0)), "Empty or whitespace-only purposes stay on the question")
    }
    let rawPurpose = "  친구에게 편지 쓰기 🧑🏽‍💻\n  café e\u{301} — отдых  \n"
    onboarding.purpose = rawPurpose
    try expect(onboarding.submitPurpose(now: time(20)), "Free-form Unicode purpose can start the real tutorial")
    try expect(onboarding.purpose == rawPurpose, "Purpose input preserves exact original wording")
    try expect(onboarding.defaultName == "친구에게 편지 쓰기 🧑🏽‍💻\n  café e\u{301} — отдых", "Only outer whitespace is removed from the saved default name")
    try expect(onboarding.step == .overview && onboarding.demonstrated.isEmpty, "Submitting a purpose does not manufacture a demonstrated skill")
    onboarding.purpose = String(repeating: "长い 목적 🐈 ", count: 1_000)
    try expect(onboarding.submitPurpose(now: time(21)), "Long Unicode purpose is accepted without arbitrary truncation")
    try expect(onboarding.purpose.count > 5_000 && onboarding.step == .overview, "Editing a purpose preserves progress and full input")

    try expect(onboarding.remainingSeconds(now: time(179)) == 1, "Countdown reaches one second normally")
    try expect(onboarding.countdownText(now: time(180)) == "0:00", "Countdown displays zero without finishing")
    try expect(onboarding.countdownText(now: time(181)) == "-0:01", "Countdown continues to a negative second")
    try expect(onboarding.countdownText(now: time(241)) == "-1:01", "Negative minutes are formatted correctly")
    try expect(!onboarding.isComplete && onboarding.step == .overview, "Going past the estimate never advances or completes the tutorial")
    onboarding.move(to: .purpose, now: time(242))
    onboarding.move(to: .overview, now: time(242))
    try expect(onboarding.countdownText == "-1:02", "Back navigation never resets the timer")
    let beforeRollback = onboarding
    try expect(onboarding.remainingSeconds(now: time(5)) == -62, "Wall-clock rollback cannot increase remaining time")
    try expect(onboarding == beforeRollback, "A backwards clock contributes no negative time or duplicate state")

    let encoded = try JSONEncoder().encode(onboarding)
    var restored = try JSONDecoder().decode(IntentOnboardingState.self, from: encoded)
    try expect(restored == onboarding, "Onboarding state round-trips its progress, text, evidence and elapsed high-water mark")
    try expect(restored.countdownText(now: time(100)) == "-1:02", "Persisted high-water mark survives a backwards-clock relaunch")
    restored.exit(now: time(250))
    let exited = restored
    restored.exit(now: time(250))
    try expect(restored == exited, "Repeated exit records only one abandonment")
    restored.begin(now: time(300))
    try expect(restored.startedAt == epoch && restored.countdownText == "-2:00", "Resume includes time away without restarting the estimate")
    try expect(restored.measurement.fullExperienceSeconds == 300, "Full experience includes the exit-to-resume gap")
    try expect(restored.measurement.coreTutorialSeconds == 250, "Active tutorial duration honestly excludes the time while closed")
    let overviewStats = restored.measurement.steps.first { $0.step == .overview }
    try expect(overviewStats?.visits == 3 && overviewStats?.abandonments == 1, "Step visits and abandonment survive back navigation and resume")

    var mastery = IntentOnboardingState(purpose: "Watch a film")
    mastery.begin(now: time(0))
    _ = mastery.submitPurpose(now: time(1))
    mastery.move(to: .quickMark, now: time(2))
    mastery.move(to: .save, now: time(3))
    mastery.move(to: .ready, now: time(4))
    try expect(mastery.demonstrated.isEmpty && mastery.evidence.isEmpty, "Next and back navigation never count as product interaction")
    mastery.move(to: .overview, now: time(5))
    _ = mastery.record(.overviewOpened, now: time(6))
    _ = mastery.record(.overviewRun, now: time(7))
    try expect(!mastery.demonstrated.contains(.overview), "Opening and running by button cannot claim the configured shortcut was performed")
    _ = mastery.record(.overviewShortcut, now: time(8))
    try expect(mastery.demonstrated == [.overview], "Overview requires shortcut, actual opening and successful run")
    try expect(mastery.firstRunAt == time(7) && mastery.measurement.timeToFirstRunSeconds == 7, "First real run is measured separately from tutorial completion")
    let afterMastery = mastery
    try expect(!mastery.record(.overviewShortcut, now: time(8)), "Duplicate evidence reports that no new event was recorded")
    try expect(mastery == afterMastery, "Duplicate evidence cannot inflate mastery or measurements")
    mastery.move(to: .quickMark, now: time(9))
    _ = mastery.record(.quickMarkShortcut, now: time(10))
    _ = mastery.record(.quickMarkChanged, now: time(11))
    try expect(!mastery.demonstrated.contains(.quickMark), "Making a quick mark without executing it is not mastery")
    _ = mastery.record(.quickMarkRun, now: time(12))
    try expect(mastery.demonstrated == [.overview, .quickMark], "Quick mark requires shortcut, actual selection change and successful run")
    try expect(mastery.firstRunAt == time(7), "Later successful runs never replace the first-run timestamp")
    mastery.move(to: .save, now: time(13))
    try expect(!mastery.record(.saved, now: time(14)), "A save event without a confirmed saved intention does not count")
    try expect(!mastery.record(.saved, now: time(14), savedIntentionID: "  \n"), "A blank saved identifier does not manufacture a save")
    try expect(!mastery.record(.reused, now: time(14), savedIntentionID: "unsaved-id"), "Reuse cannot establish a save that never happened")
    try expect(!mastery.demonstrated.contains(.save), "Only a successful real save demonstrates saving")
    try expect(mastery.record(.saved, now: time(15), savedIntentionID: "saved-1"), "A confirmed real save counts")
    try expect(mastery.demonstrated == Set(IntentOnboardingSkill.allCases), "The three real skills can all be demonstrated")
    try expect(!mastery.record(.saved, now: time(15), savedIntentionID: "duplicate-2"), "An existing saved ID cannot be replaced by a duplicate on retry")
    try expect(mastery.savedIntentionID == "saved-1", "The first confirmed save identity stays pinned")
    _ = mastery.record(.reused, now: time(16), savedIntentionID: "saved-1")
    try expect(mastery.evidence.contains(.reused), "Using the actual saved intention can be recorded separately")
    try expect(mastery.finish(now: time(17)), "Finishing records a completed tutorial")
    let finished = mastery
    mastery.begin(now: time(50))
    mastery.observe(now: time(100))
    mastery.move(to: .purpose, now: time(100))
    try expect(!mastery.finish(now: time(100)) && mastery == finished, "A completed attempt stays stable until explicitly replayed")
    try expect(mastery.completedAt == time(17), "Completion timestamp belongs to the successful attempt")

    mastery.replay(now: time(200))
    try expect(mastery.step == .welcome && !mastery.hasStarted && !mastery.isActive, "Replay returns to an unstarted welcome, not an auto-started countdown")
    try expect(mastery.purpose == "Watch a film" && mastery.savedIntentionID == "saved-1", "Replay preserves the user's purpose and reusable saved ID")
    try expect(mastery.evidence.isEmpty && mastery.demonstrated.isEmpty && mastery.countdownText == "3:00", "Replay requires fresh demonstrated skills and starts a new estimate")
    mastery.begin(now: time(200))
    _ = mastery.submitPurpose(now: time(201))
    try expect(!mastery.record(.saved, now: time(202), savedIntentionID: "duplicate-2"), "Replay cannot silently establish another saved intention")
    try expect(mastery.record(.saved, now: time(203), savedIntentionID: "saved-1"), "Replay may update the same saved intention without duplication")
    try expect(mastery.record(.reused, now: time(204), savedIntentionID: "saved-1"), "Replay can genuinely reuse the preserved intention")

    var skipped = IntentOnboardingState(purpose: "Relax")
    skipped.begin(now: time(0))
    _ = skipped.submitPurpose(now: time(1))
    try expect(skipped.skipCurrent(now: time(2)) && skipped.step == .quickMark, "Overview offers an honest skip path")
    try expect(skipped.skipCurrent(now: time(3)) && skipped.step == .save, "Quick mark offers an honest skip path")
    try expect(skipped.skipCurrent(now: time(4)) && skipped.step == .ready, "Saving remains optional")
    try expect(skipped.skipped == Set(IntentOnboardingSkill.allCases) && skipped.demonstrated.isEmpty, "Skipped steps never count as demonstrated mastery")
    skipped.move(to: .overview, now: time(5))
    _ = skipped.record(.overviewShortcut, now: time(6))
    _ = skipped.record(.overviewOpened, now: time(6))
    _ = skipped.record(.overviewRun, now: time(7))
    try expect(skipped.demonstrated == [.overview] && !skipped.skipped.contains(.overview), "A skipped skill can later be genuinely demonstrated")
    _ = skipped.finish(now: time(8))
    try expect(skipped.isComplete && skipped.demonstrated == [.overview], "Flow completion is kept distinct from skill completion")

    var setup = IntentOnboardingState(purpose: "Private purpose: https://private.example/secret")
    setup.begin(now: time(0))
    _ = setup.submitPurpose(now: time(10))
    setup.setSetupInProgress(true, now: time(20))
    setup.observe(now: time(260))
    try expect(setup.countdownText == "-1:20", "Required setup time never pauses or manipulates the visible countdown")
    setup.setSetupInProgress(false, now: time(260))
    _ = setup.record(.overviewRun, now: time(270))
    _ = setup.record(.saved, now: time(271), savedIntentionID: "private-saved-id")
    _ = setup.finish(now: time(280))
    try expect(setup.measurement.fullExperienceSeconds == 280, "Full first-run experience includes all required setup")
    try expect(setup.measurement.requiredSetupSeconds == 240 && setup.measurement.coreTutorialSeconds == 40, "Setup and active core duration are measured separately without hiding setup cost")
    try expect(setup.measurement.timeToFirstRunSeconds == 270, "Time to real first success includes prerequisite work")
    let diagnosticJSON = String(data: try JSONEncoder().encode(setup.measurement), encoding: .utf8)!
    try expect(!diagnosticJSON.contains("Private purpose") && !diagnosticJSON.contains("private.example") && !diagnosticJSON.contains("private-saved-id"), "Diagnostic measurements exclude purpose text, URLs, titles and saved IDs")
    let restoredSetup = try JSONDecoder().decode(IntentOnboardingState.self, from: JSONEncoder().encode(setup))
    try expect(restoredSetup == setup && restoredSetup.measurement == setup.measurement, "Completed measurements and lifecycle state survive persistence")

    var absent = IntentOnboardingState(purpose: "Read")
    absent.begin(now: time(0))
    absent.exit(now: time(1))
    try expect(!absent.record(.overviewRun, now: time(2)), "Product use after tutorial exit cannot fabricate tutorial evidence")
    try expect(absent.firstRunAt == nil, "Absent tutorial does not claim an observed first success")

    var lateSave = IntentOnboardingState(purpose: "My real setup")
    lateSave.begin(now: time(0))
    _ = lateSave.submitPurpose(now: time(1))
    _ = lateSave.record(.overviewRun, now: time(2))
    lateSave.exit(now: time(3))
    let exitedMeasurements = lateSave.measurement
    try expect(lateSave.retainSavedIntentionID("saved-after-exit"), "A real asynchronous save retains its identity after the guide has exited")
    try expect(lateSave.savedIntentionID == "saved-after-exit" && !lateSave.isActive && lateSave.measurement == exitedMeasurements,
        "Late-save bookkeeping cannot restart the guide or manufacture timing, evidence, or mastery")
    try expect(!lateSave.record(.saved, now: time(4), savedIntentionID: "saved-after-exit") && !lateSave.demonstrated.contains(.save),
        "A late successful save still cannot claim the closed tutorial observed its save skill")
    try expect(!lateSave.retainSavedIntentionID("duplicate-later") && lateSave.savedIntentionID == "saved-after-exit",
        "Late storage bookkeeping cannot replace a still-pinned saved identity")
    var lateReloaded = try JSONDecoder().decode(IntentOnboardingState.self, from: JSONEncoder().encode(lateSave))
    lateReloaded.replay()
    try expect(lateReloaded.savedIntentionID == "saved-after-exit" && lateReloaded.evidence.isEmpty && lateReloaded.demonstrated.isEmpty,
        "Exit, persistence and replay retain a late saved ID while requiring fresh tutorial practice")
    let persistedLate = Intention(id: "saved-after-exit", name: "My real setup", icon: "square", colorHex: "#34C759", folder: "",
        allowedApps: [], allowedWebsites: [], startupActions: [], restrictions: .init())
    let replayDraft = Intention(id: "new-replay-draft", name: "New attempt", icon: "square", colorHex: "#34C759", folder: "",
        allowedApps: [], allowedWebsites: [], startupActions: [], restrictions: .init())
    let lateReplayPlan = OnboardingSavePlan(candidate: replayDraft, latestPurpose: lateReloaded.defaultName,
        existing: [persistedLate].first(where: { $0.id == lateReloaded.savedIntentionID }), replaceExisting: false, insertionPosition: .zero)
    try expect(lateReplayPlan.action == .keepExisting && lateReplayPlan.intention.id == persistedLate.id,
        "Replaying after a late save consumes the retained identity and keeps the existing setup rather than inserting a duplicate")
    lateReloaded.begin(now: time(5))
    _ = lateReloaded.finish(now: time(6))
    let completedMeasurements = lateReloaded.measurement
    _ = lateReloaded.retainSavedIntentionID("saved-after-exit")
    try expect(lateReloaded.isComplete && lateReloaded.measurement == completedMeasurements,
        "Late-save bookkeeping also leaves a completed tutorial and its mastery measurements unchanged")

    var interrupted = IntentOnboardingState(purpose: "Resume a book")
    interrupted.begin(now: time(0))
    _ = interrupted.submitPurpose(now: time(1))
    interrupted.setSetupInProgress(true, now: time(20))
    interrupted.observe(now: time(30))
    var relaunched = try JSONDecoder().decode(IntentOnboardingState.self, from: JSONEncoder().encode(interrupted))
    relaunched.resumeAfterRelaunch(now: time(1_000))
    try expect(!relaunched.isActive && !relaunched.isSetupInProgress, "Relaunch leaves persisted tutorial and setup inactive until presentation")
    try expect(relaunched.measurement.coreTutorialSeconds == 20 && relaunched.measurement.requiredSetupSeconds == 10, "Unknown time after a crash is not fabricated as active tutorial or setup work")
    try expect(relaunched.measurement.fullExperienceSeconds == 1_000 && relaunched.countdownText == "-13:40", "Relaunch retains the full elapsed estimate across a long absence")
    try expect(relaunched.measurement.steps.first { $0.step == .overview }?.abandonments == 1, "Interrupted active step records one abandonment on relaunch")
    let recovered = relaunched
    relaunched.resumeAfterRelaunch(now: time(1_000))
    try expect(relaunched == recovered, "Repeated relaunch recovery cannot double-count the interruption")
    relaunched.begin(now: time(1_010))
    relaunched.observe(now: time(1_020))
    try expect(relaunched.startedAt == epoch && relaunched.step == .overview, "Relaunch resumes the actual step and original start date")
    try expect(relaunched.measurement.coreTutorialSeconds == 30 && relaunched.measurement.requiredSetupSeconds == 10, "Only newly observed active time contributes after relaunch")

    let preservedSave = mastery
    try expect(!mastery.forgetSavedIntention(ifMissingFrom: ["saved-1", "another-id"]) && mastery == preservedSave, "Reconciliation never replaces or clears a still-existing saved intention")
    _ = mastery.record(.overviewShortcut, now: time(205))
    _ = mastery.record(.overviewOpened, now: time(205))
    _ = mastery.record(.overviewRun, now: time(206))
    let progressBeforeDeletion = mastery
    try expect(mastery.forgetSavedIntention(ifMissingFrom: ["another-id"]), "An actually deleted saved intention is detected")
    try expect(mastery.savedIntentionID == nil && !mastery.evidence.contains(.saved) && !mastery.evidence.contains(.reused) && !mastery.demonstrated.contains(.save), "Deleted saved intentions clear stale save and reuse claims")
    try expect(mastery.purpose == progressBeforeDeletion.purpose && mastery.step == progressBeforeDeletion.step && mastery.startedAt == progressBeforeDeletion.startedAt && mastery.firstRunAt == progressBeforeDeletion.firstRunAt && mastery.observedElapsedSeconds == progressBeforeDeletion.observedElapsedSeconds, "Deleted-save recovery preserves purpose, navigation, first success and timing")
    try expect(mastery.demonstrated.contains(.overview) && mastery.evidence.contains(.overviewRun), "Deleted-save recovery preserves unrelated skill evidence")
    try expect(!mastery.forgetSavedIntention(ifMissingFrom: []), "Repeated missing-save reconciliation is idempotent")
    try expect(mastery.record(.saved, now: time(207), savedIntentionID: "replacement-3") && mastery.savedIntentionID == "replacement-3", "A deleted intention can be genuinely saved again with a fresh identity")
}
