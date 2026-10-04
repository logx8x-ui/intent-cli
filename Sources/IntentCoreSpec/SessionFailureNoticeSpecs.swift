import Foundation
import IntentCore

func runSessionFailureNoticeSpecs() throws {
    let first = UUID(), second = UUID()
    var policy = SessionFailureNoticePolicy()
    try expect(policy.show(occurrenceID: first, canPresent: true) == nil,
        "Unarmed notices cannot appear for arbitrary or old session identities")
    try expect(policy.prepare(occurrenceID: first), "Every actual session arms feedback even without a timer")
    policy.hide() // Normal teardown first removes old controls/feedback.
    guard let token = policy.show(occurrenceID: first, canPresent: true) else {
        throw SpecFailure(description: "Failure did not survive its own ordinary cleanup")
    }
    try expect(policy.visible, "A typed failure can display after timer/control cleanup")
    try expect(!policy.prepare(occurrenceID: first) && policy.show(occurrenceID: first, canPresent: true) == nil,
        "Repeated preparation cannot rearm a consumed occurrence")
    try expect(policy.expire(generation: token) && !policy.visible,
        "The finite dismissal expires only its own visible notice")
    try expect(!policy.expire(generation: token) && policy.show(occurrenceID: first, canPresent: true) == nil,
        "A dismissed notice cannot repeat for the same occurrence")
    _ = policy.prepare(occurrenceID: second)
    guard let nextToken = policy.show(occurrenceID: second, canPresent: true) else {
        throw SpecFailure(description: "A new session did not get its own failure notice")
    }
    try expect(!policy.expire(generation: token) && policy.visible,
        "A canceled old dismissal cannot hide a newer notice")
    try expect(policy.show(occurrenceID: first, canPresent: true) == nil && policy.visible,
        "A stale old occurrence cannot replace the new one")
    policy.hide()
    try expect(!policy.expire(generation: nextToken) && !policy.visible, "Sleep/lock hiding cancels the timer generation")

    var security = SessionFailureNoticePolicy()
    _ = security.prepare(occurrenceID: first)
    try expect(security.show(occurrenceID: first, canPresent: false) == nil && !security.visible,
        "Locked, non-console or missing-screen attempts are consumed without displaying")
    try expect(security.show(occurrenceID: first, canPresent: true) == nil,
        "Unlock cannot replay a failure suppressed at the security boundary")
    _ = security.prepare(occurrenceID: second)
    security.suppressForSecurity()
    try expect(!security.resume(occurrenceID: second, sessionStillRunning: false),
        "A stopped or failed lock cannot rearm a queued old notice on wake")
    try expect(security.show(occurrenceID: second, canPresent: true) == nil,
        "A failure callback queued behind sleep cannot show on wake for that old session")
    try expect(!security.resume(occurrenceID: second, sessionStillRunning: true),
        "Even a claimed running session cannot replay an already-consumed security failure")
    let third = UUID()
    _ = security.prepare(occurrenceID: third)
    try expect(security.show(occurrenceID: third, canPresent: true) != nil,
        "A genuinely new session can report its own failure after wake")
    _ = security.prepare(occurrenceID: UUID())
    try expect(!security.visible, "Starting any new session cancels previous feedback without showing anything")

    var ongoing = SessionFailureNoticePolicy()
    _ = ongoing.prepare(occurrenceID: first)
    ongoing.suppressForSecurity()
    try expect(!ongoing.resume(occurrenceID: second, sessionStillRunning: true),
        "A stale or different occurrence cannot rearm security-suppressed feedback")
    try expect(ongoing.resume(occurrenceID: first, sessionStillRunning: true)
        && !ongoing.resume(occurrenceID: first, sessionStillRunning: true),
        "An exact still-running session resumes once without displaying old feedback")
    guard let resumedToken = ongoing.show(occurrenceID: first, canPresent: true) else {
        throw SpecFailure(description: "A fresh enforcement failure after wake was incorrectly muted")
    }
    ongoing.suppressForSecurity()
    try expect(!ongoing.resume(occurrenceID: first, sessionStillRunning: true)
        && !ongoing.expire(generation: resumedToken) && !ongoing.visible,
        "Locking hides an already-presented notice and wake never replays it or its dismissal")
    try expect(SessionFailureNoticePolicy.duration > 0 && SessionFailureNoticePolicy.duration <= 15,
        "Failure feedback has one short finite lifetime, not an idle polling loop")

    for (screen, visible, inset) in [
        (CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 0, y: 30, width: 1512, height: 920), CGFloat(32)),
        (CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: -1920, y: 30, width: 1920, height: 1026), CGFloat(0)),
        (CGRect(x: 100, y: -900, width: 800, height: 600), CGRect(x: 100, y: -875, width: 800, height: 550), CGFloat(0))
    ] {
        let frame = SessionFailureNoticePolicy.frame(screen: screen, visibleFrame: visible, safeAreaTop: inset)
        try expect(visible.contains(frame) && frame.maxY < screen.maxY - inset,
            "Failure text sits below the camera/menu area and within each display's visible bounds")
        try expect(frame.midX == visible.midX && frame.width <= 440 && frame.height <= 148,
            "The notice stays compact and centered, including external displays with negative origins")
    }
}
