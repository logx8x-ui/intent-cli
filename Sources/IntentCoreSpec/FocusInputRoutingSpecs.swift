import CoreGraphics
import Foundation
import IntentCore
import IntentLock

func runFocusInputRoutingSpecs() throws {
    let config = FocusInputConfiguration()
    var state = FocusInputPolicySnapshot()
    state.observedAt = 10
    state.windows = [.init(id: 20, bounds: CGRect(x: 0, y: 0, width: 400, height: 400), permitted: false)]
    var router = FocusInputRouter()
    func key(_ code: Int64, _ flags: CGEventFlags = [], repeatKey: Bool = false, up: Bool = false) -> FocusInputEvent {
        .init(type: up ? .keyUp : .keyDown, keyCode: code, flags: flags, isRepeat: repeatKey)
    }
    let commandTab = router.route(key(48, .maskCommand), snapshot: state, configuration: config, now: 10)
    try expect(commandTab.consume && commandTab.actions == [.switcherAdvance(steps: 1)], "Command Tab is consumed and scheduled without touching AppKit")
    let release = router.route(.init(type: .flagsChanged), snapshot: state, configuration: config, now: 10.01)
    try expect(release.actions == [.switcherCommit], "Command release commits once outside the input callback")
    try expect(router.route(key(48, up: true), snapshot: state, configuration: config, now: 10.02).consume,
        "Consumed key down owns key up after modifier release")
    for shift in [false, true] {
        let flags: CGEventFlags = shift ? [.maskControl, .maskShift] : .maskControl
        try expect(!router.route(key(48, flags, repeatKey: true), snapshot: state, configuration: config, now: 10.03).consume,
            "Native Control Tab and repeats never invoke the application switcher")
    }
    state.rcmd = .init(processIdentity: .init(pid: 123, launched: 1, version: "3.4.0"),
        observedAtUptime: 10, isCompatible: true, statusReason: nil, appTrigger: .init(description: "rcmd"),
        blockedTriggers: [RcmdModifierChord(description: "rcmd")!, RcmdModifierChord(description: "rctrl")!],
        appBundlesByKeyCode: [0: "allowed.app"], tapIDs: [1], capturesCommandGrave: false, configurationFingerprint: "fixture")
    let rightControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
    for code: Int64 in [48, 123, 124] {
        try expect(router.route(key(code, rightControl), snapshot: state, configuration: config, now: 10.04).consume,
            "A configured rcmd stage trigger cannot bypass Intent through Control-Tab or Space exceptions")
        _ = router.route(key(code, up: true), snapshot: state, configuration: config, now: 10.05)
    }
    try expect(!router.route(key(48, .maskControl), snapshot: state, configuration: config, now: 10.06).consume,
        "Ordinary Control-Tab remains native with rcmd enabled")
    let liveRcmd = state.rcmd
    state.rcmd = .inactive
    state.foregroundRejected = true
    let typed = router.route(key(0), snapshot: state, configuration: config, now: 10.1)
    try expect(typed.consume && typed.actions == [.refocus], "An excluded app remains inert while bounded recovery catches up")
    try expect(!router.route(key(50), snapshot: state, configuration: config, now: 10.1).consume, "Grave controls remain owned by their original controller")
    for code: Int64 in [20, 21, 23] {
        try expect(!router.route(key(code, [.maskCommand, .maskShift]), snapshot: state, configuration: config, now: 10.1).consume,
            "macOS screenshot shortcuts remain available over excluded apps")
    }
    let emergency = router.route(key(53, [.maskCommand, .maskControl, .maskAlternate]), snapshot: state, configuration: config, now: 10.2)
    try expect(emergency.consume && emergency.actions == [.emergencyStop], "Emergency recovery has an independent priority action")
    let finish = router.route(key(46, [.maskCommand, .maskShift]), snapshot: state, configuration: config, now: 10.2)
    try expect(finish.consume && finish.actions == [.manualFinish], "Manual finish is scheduled without restoration in the callback")
    try expect(router.route(key(46, [.maskCommand, .maskShift], repeatKey: true), snapshot: state, configuration: config, now: 10.2).actions.isEmpty,
        "A held finish shortcut cannot enqueue repeated completion")

    let click = FocusInputEvent(type: .leftMouseDown, point: CGPoint(x: 50, y: 50), targetWindowID: 20)
    try expect(router.route(click, snapshot: state, configuration: config, now: 10.3).consume, "Exact excluded-window clicks are withheld")
    try expect(router.route(.init(type: .leftMouseDragged), snapshot: state, configuration: config, now: 10.31).consume,
        "The matching drag is not delivered without its down")
    state.missionControl = true; state.pointerProbe = click.point; state.pointerPermitted = true
    try expect(!router.route(click, snapshot: state, configuration: config, now: 10.4).consume,
        "Mission Control uses the sampled tile/Space identity, not the untransformed window underneath it")
    try expect(router.route(.init(type: .leftMouseUp), snapshot: state, configuration: config, now: 10.41).consume,
        "A consumed mouse down owns its release across a workspace transition")
    state.missionControl = false
    state.windows = [.init(id: 20, bounds: CGRect(x: 0, y: 0, width: 400, height: 400), permitted: true)]
    try expect(router.route(.init(type: .leftMouseDown, point: click.point, targetWindowID: 21),
        snapshot: state, configuration: config, now: 10.45).consume,
        "An unknown newly opened window cannot inherit the allowed rectangle underneath it")
    state.panelRegions = [CGRect(x: 40, y: 40, width: 50, height: 50)]
    try expect(!router.route(click, snapshot: state, configuration: config, now: 10.5).consume, "Explicit Intent controls stay clickable")
    state.screenshotActive = true
    try expect(!router.route(click, snapshot: state, configuration: config, now: 10.5).consume,
        "Active screenshot capture keeps mouse delivery over a blocked window")
    try expect(router.route(key(53, [.maskCommand, .maskControl, .maskAlternate]), snapshot: state, configuration: config, now: 10.5).actions == [.emergencyStop],
        "Screenshot capture does not bypass Intent's emergency shortcut")
    try expect(router.route(key(46, [.maskCommand, .maskShift]), snapshot: state, configuration: config, now: 10.5).actions == [.manualFinish],
        "Screenshot capture does not bypass Intent's manual finish shortcut")
    state.rcmd = liveRcmd; state.allowedSwitchingBundles = ["allowed.app"]
    try expect(router.route(key(0, .init(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)),
        snapshot: state, configuration: config, now: 10.5).actions == [.activate("allowed.app")],
        "rcmd remains routed through permitted destinations even while screenshot capture is open")
    _ = router.route(key(0, up: true), snapshot: state, configuration: config, now: 10.5)
    state.rcmd = .inactive
    state.screenshotActive = false; state.panelRegions = []
    state.windows = [30, 31].map { .init(id: UInt32($0), bounds: CGRect(x: 0, y: 0, width: 400, height: 400), permitted: true) }
    state.tabWindowID = 30; state.tabRegions = [CGRect(x: 0, y: 0, width: 300, height: 40)]
    state.tabRegionsValidUntil = 11
    try expect(!router.route(.init(type: .leftMouseDown, point: CGPoint(x: 10, y: 10), targetWindowID: 31),
        snapshot: state, configuration: config, now: 10.6).consume, "A tab mask never bleeds into a sibling window")
    try expect(router.route(.init(type: .leftMouseDown, point: CGPoint(x: 10, y: 10), targetWindowID: 30),
        snapshot: state, configuration: config, now: 10.6).consume, "The exact fresh blocked-tab mask still intercepts input")
    state.observedAt = 11.1
    try expect(!router.route(.init(type: .leftMouseDown, point: CGPoint(x: 10, y: 10), targetWindowID: 30),
        snapshot: state, configuration: config, now: 11.1).consume, "Expired tab geometry cannot block an unrelated reflowed tab")

    try expect(FocusInputForegroundPolicy.rejectsWindow(hasWindowScope: true, foregroundWindowID: 31,
        windowPermitted: false, auxiliaryVerified: false), "A partially permitted native app cannot type into an excluded sibling")
    try expect(!FocusInputForegroundPolicy.rejectsWindow(hasWindowScope: true, foregroundWindowID: 31,
        windowPermitted: false, auxiliaryVerified: true), "A currently proven auxiliary surface retains input")
    try expect(FocusInputForegroundPolicy.rejectsWindow(hasWindowScope: true, foregroundWindowID: 0,
        windowPermitted: true, auxiliaryVerified: false), "Unknown foreground window identity cannot expand selected-window scope")
    try expect(!FocusInputForegroundPolicy.rejectsWindow(hasWindowScope: false, foregroundWindowID: 0,
        windowPermitted: false, auxiliaryVerified: false), "Whole-app selection does not acquire a selected-window limitation")
    state.foregroundRejected = false; state.observedAt = 11.2
    let consumed = router.route(key(12, .maskCommand), snapshot: state, configuration: config, now: 11.2)
    try expect(consumed.consume, "System quit is withheld before a modified repeat")
    try expect(router.route(key(12, [], repeatKey: true), snapshot: state, configuration: config, now: 11.21).consume,
        "A swallowed down owns repeats after modifier release")
    _ = router.route(key(12, up: true), snapshot: state, configuration: config, now: 11.22)

    var pending = FocusInputPendingEffects()
    pending.append([.switcherAdvance(steps: 1), .switcherAdvance(steps: 1), .switcherAdvance(steps: -1), .switcherCommit])
    try expect(pending.take() == [.switcherAdvance(steps: 1), .switcherCommit], "Coalescing keeps the exact net switcher selection and release order")
    for _ in 0..<1_000 { pending.append([.switcherAdvance(steps: 1), .switcherCommit]) }
    pending.append([.switcherCancel])
    try expect(pending.actions.count <= 16 && pending.actions.last == .switcherCancel,
        "Queue saturation can never lose the terminal cancel and leave a chooser stuck visible")
    _ = pending.take()
    var manual = FocusInputManualFinishPolicy()
    try expect(manual.request(), "First finish press starts one owner request")
    for _ in 0..<10_000 { try expect(!manual.request(), "A stalled completion owner receives only one finish request") }
    manual.acknowledge()
    try expect(manual.request(), "A declined friction prompt can be requested again after acknowledgement")
    let blockedWorker = DispatchSemaphore(value: 0)
    let workerStarted = DispatchSemaphore(value: 0)
    let workerDone = DispatchSemaphore(value: 0)
    DispatchQueue(label: "intent.spec.stalled-window-worker").async {
        workerStarted.signal()
        _ = blockedWorker.wait(timeout: .now() + 2)
        workerDone.signal()
    }
    _ = workerStarted.wait(timeout: .now() + 1)
    let began = ProcessInfo.processInfo.systemUptime
    var maximumCallback: TimeInterval = 0
    state.foregroundRejected = true
    state.observedAt = 12
    for index in 0..<10_000 {
        let eventStart = ProcessInfo.processInfo.systemUptime
        let result = router.route(key(12, .maskCommand), snapshot: state, configuration: config, now: 12 + Double(index) / 10000)
        try expect(result.consume, "Every excluded-route event stays consumed while the window worker stalls")
        pending.append(result.actions)
        _ = router.route(key(12, up: true), snapshot: state, configuration: config, now: 12 + Double(index) / 10000)
        maximumCallback = max(maximumCallback, ProcessInfo.processInfo.systemUptime - eventStart)
        try expect(pending.actions.count <= 16, "Ten thousand events cannot create an unbounded deferred queue")
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - began
    try expect(elapsed < 1.5 && maximumCallback < 0.1,
        "Production input routing must finish independently of the two-second blocked window worker")
    try expect(workerDone.wait(timeout: .now()) == .timedOut, "The burst completed before the stalled worker, not after it recovered")
    try expect(pending.take() == [.refocus], "Ten thousand refocus requests collapse to one pending action")
    blockedWorker.signal()
    _ = workerDone.wait(timeout: .now() + 1)
    state.stopped = true
    try expect(router.route(key(12, .maskCommand), snapshot: state, configuration: config, now: 13).actions.isEmpty,
        "A cancelled occurrence cannot create late activation or completion work")

    var recovery = FocusInputRecoveryPolicy()
    try expect(recovery.interrupted(timeout: true, now: 20), "First response timeout permits one repair of the existing tap")
    try expect(recovery.verify(now: 20.1, tapEnabled: true, trusted: true, coverageResolved: true,
        coverageVerifiedAt: 19.9, snapshotObservedAt: 20.1) != .healthy, "Sticky startup coverage cannot certify timeout recovery")
    try expect(recovery.verify(now: 20.2, tapEnabled: true, trusted: true, coverageResolved: true,
        coverageVerifiedAt: 20.1, snapshotObservedAt: 20.1) == .healthy, "Fresh permission, tap and coverage proofs resume the same occurrence")
    try expect(!recovery.interrupted(timeout: true, now: 20.3) && recovery.state == .failed, "A second timeout cannot loop through repair")
    var denied = FocusInputRecoveryPolicy()
    try expect(!denied.interrupted(timeout: false, now: 30) && denied.state == .failed, "User-disabled input protection never auto-reenables")
    var expired = FocusInputRecoveryPolicy()
    _ = expired.interrupted(timeout: true, now: 40)
    try expect(expired.verify(now: 41, tapEnabled: true, trusted: true, coverageResolved: true,
        coverageVerifiedAt: 40.8, snapshotObservedAt: 40.9) == .failed, "Proof arriving at the one-second deadline is too late")
    var finished = FocusInputRecoveryPolicy()
    _ = finished.interrupted(timeout: true, now: 50); finished.stop()
    try expect(finished.verify(now: 50.2, tapEnabled: true, trusted: true, coverageResolved: true,
        coverageVerifiedAt: 50.1, snapshotObservedAt: 50.1) == .stopped, "Manual finish wins over a successful delayed repair")
}
