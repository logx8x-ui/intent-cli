import CoreGraphics
import Foundation
import Darwin

/// A producer may hold this lock only while swapping a value. The input thread
/// never waits for it: contention retains the last complete immutable snapshot.
final class FocusInputSnapshotMailbox: @unchecked Sendable {
    private let mutex = NSLock()
    private var snapshot: FocusInputPolicySnapshot
    init(_ snapshot: FocusInputPolicySnapshot) { self.snapshot = snapshot }
    func publish(_ snapshot: FocusInputPolicySnapshot) { mutex.lock(); if !self.snapshot.stopped { self.snapshot = snapshot }; mutex.unlock() }
    func readIfAvailable() -> FocusInputPolicySnapshot? {
        guard mutex.try() else { return nil }
        defer { mutex.unlock() }; return snapshot
    }
    func cancel() { mutex.lock(); snapshot.stopped = true; mutex.unlock() }
}

/// Epoch-only atomic fence: readers never hold a lock across UI/AX work and
/// revocation from the input thread never waits for another thread.
final class FocusInputEffectEpoch: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Int64>
    init() { storage = .allocate(capacity: 1); storage.initialize(to: 0) }
    deinit { storage.deinitialize(count: 1); storage.deallocate() }
    var current: Int64 { OSAtomicAdd64Barrier(0, storage) }
    func invalidate() { OSAtomicIncrement64Barrier(storage) }
}

public struct FocusInputMetrics {
    public var samples = 0
    public var maxDurationMicroseconds: Double = 0
    public var maxSnapshotAgeMilliseconds: Double = 0
    public var maxPendingActions = 0
    public var coalescedActions = 0
    public var schedulingDelayMilliseconds: Double = 0
}

/// The lifetime of this object is the lifetime of one intention. CoreGraphics
/// delivery and its timer have a dedicated run loop with no AX/UI/discovery work.
/// The tap only routes scalar events, updates bounded state and posts work.
final class FocusInputTapDriver: @unchecked Sendable {
    enum Control { case recoveryBegan, recoverySucceeded, failed(FocusLockSafetyStopCause), manualFinish, emergencyStop }
    private let mailbox: FocusInputSnapshotMailbox
    private let configuration: FocusInputConfiguration
    private let onEffects: ([FocusInputAction], @escaping () -> Bool) -> Void
    private let effectEpoch = FocusInputEffectEpoch()
    private let onControl: (Control) -> Void
    private let onMetrics: (FocusInputMetrics) -> Void
    private let controls = DispatchQueue(label: "intent.input-control", qos: .userInteractive)
    private let lifecycleMutex = NSLock()
    private var inputLoop: CFRunLoop?
    private var shutdown = false
    private var setupSucceeded = false
    private let completionMutex = NSLock()
    private var completedBatch = true
    // All following fields are owned exclusively by the input thread.
    private var cachedSnapshot: FocusInputPolicySnapshot
    private var router = FocusInputRouter()
    private var pending = FocusInputPendingEffects()
    private var batchOutstanding = false
    private var recovery = FocusInputRecoveryPolicy()
    private var tap: CFMachPort?
    private var metrics = FocusInputMetrics()
    private var lastMetrics: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var failedReported = false
    private var finishing = false
    private var manualFinish = FocusInputManualFinishPolicy()
    private let manualAcknowledgement = FocusInputEffectEpoch()
    private var pendingAcknowledgementEpoch: Int64 = 0

    init(snapshot: FocusInputPolicySnapshot, configuration: FocusInputConfiguration,
         onEffects: @escaping ([FocusInputAction], @escaping () -> Bool) -> Void, onControl: @escaping (Control) -> Void,
         onMetrics: @escaping (FocusInputMetrics) -> Void) {
        mailbox = .init(snapshot); cachedSnapshot = snapshot; self.configuration = configuration
        self.onEffects = onEffects; self.onControl = onControl; self.onMetrics = onMetrics
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in run(ready: ready) }
        thread.name = "Intent input protection"
        thread.qualityOfService = .userInteractive
        thread.start()
        guard ready.wait(timeout: .now() + 3) == .success else { stop(); throw FocusLockError.eventTapUnavailable }
        lifecycleMutex.lock(); let succeeded = setupSucceeded; lifecycleMutex.unlock()
        guard succeeded else { throw FocusLockError.eventTapUnavailable }
    }
    func publish(_ snapshot: FocusInputPolicySnapshot) { mailbox.publish(snapshot) }
    func acknowledgeManualFinishRequest() { manualAcknowledgement.invalidate() }
    func stop() {
        effectEpoch.invalidate()
        mailbox.cancel()
        lifecycleMutex.lock(); shutdown = true; let loop = inputLoop; lifecycleMutex.unlock()
        if let loop { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) }
    }

    private func run(ready: DispatchSemaphore) {
        let loop = CFRunLoopGetCurrent()
        lifecycleMutex.lock(); inputLoop = loop; let cancelled = shutdown; lifecycleMutex.unlock()
        if cancelled { ready.signal(); return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDragged, .scrollWheel,
            .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<FocusInputTapDriver>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            ready.signal(); return
        }
        tap = created
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.current.add(timer, forMode: .common)
        lifecycleMutex.lock(); setupSucceeded = CGEvent.tapIsEnabled(tap: created); let stopped = shutdown; lifecycleMutex.unlock()
        lastTick = ProcessInfo.processInfo.systemUptime; lastMetrics = lastTick
        ready.signal()
        if !stopped { CFRunLoopRun() }
        recovery.stop(); finishing = true; timer.invalidate()
        CGEvent.tapEnable(tap: created, enable: false); CFMachPortInvalidate(created)
        CFRunLoopRemoveSource(loop, source, .commonModes); tap = nil
        lifecycleMutex.lock(); inputLoop = nil; lifecycleMutex.unlock()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let began = ProcessInfo.processInfo.systemUptime
        if let snapshot = mailbox.readIfAvailable() { cachedSnapshot = snapshot }
        defer {
            metrics.samples = min(1_000_000, metrics.samples + 1)
            metrics.maxDurationMicroseconds = max(metrics.maxDurationMicroseconds,
                (ProcessInfo.processInfo.systemUptime - began) * 1_000_000)
            metrics.maxSnapshotAgeMilliseconds = max(metrics.maxSnapshotAgeMilliseconds,
                max(0, began - cachedSnapshot.observedAt) * 1_000)
        }
        if cachedSnapshot.stopped || finishing { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let isTimeout = type == .tapDisabledByTimeout
            effectEpoch.invalidate()
            _ = pending.take()
            if recovery.interrupted(timeout: isTimeout, now: began), let tap, CFMachPortIsValid(tap) {
                dispatchControl(.recoveryBegan)
                // One enable of the same tap. No re-creation, competing taps, or
                // replay. Actual coverage verification occurs outside callback.
                CGEvent.tapEnable(tap: tap, enable: true)
            } else { fail(isTimeout ? .inputTapTimeout : .inputTapDisabled) }
            return Unmanaged.passUnretained(event)
        }
        let input = FocusInputEvent(type: type,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            point: event.location, button: event.getIntegerValueField(.mouseEventButtonNumber),
            targetWindowID: UInt32(clamping: event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)))
        let decision = router.route(input, snapshot: cachedSnapshot, configuration: configuration, now: began)
        for action in decision.actions {
            switch action {
            case .emergencyStop:
                finishing = true; recovery.stop(); effectEpoch.invalidate(); _ = pending.take(); dispatchControl(.emergencyStop)
            case .manualFinish:
                if !finishing, manualFinish.request() {
                    effectEpoch.invalidate(); _ = pending.take()
                    pendingAcknowledgementEpoch = manualAcknowledgement.current
                    dispatchControl(.manualFinish)
                }
            default:
                // Recovery freezes activation work, while ordinary input is still
                // judged by the last exact policy. Never release restrictions.
                if recovery.state == .healthy && !manualFinish.pending { pending.append([action]) }
            }
        }
        metrics.maxPendingActions = max(metrics.maxPendingActions, pending.actions.count)
        return decision.consume ? nil : Unmanaged.passUnretained(event)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        metrics.schedulingDelayMilliseconds = max(metrics.schedulingDelayMilliseconds, max(0, now - lastTick - 0.01) * 1_000)
        lastTick = now
        if manualFinish.pending && manualAcknowledgement.current != pendingAcknowledgementEpoch {
            manualFinish.acknowledge()
        }
        if let snapshot = mailbox.readIfAvailable() { cachedSnapshot = snapshot }
        if cachedSnapshot.stopped { finishing = true; recovery.stop(); CFRunLoopStop(CFRunLoopGetCurrent()); return }
        if now - cachedSnapshot.observedAt <= 0.6, !cachedSnapshot.accessibilityTrusted {
            fail(.accessibilityPermissionRequired)
        }
        if case .recovering = recovery.state {
            let result = recovery.verify(now: now, tapEnabled: tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false,
                trusted: cachedSnapshot.accessibilityTrusted, coverageResolved: cachedSnapshot.coverageResolved,
                coverageVerifiedAt: cachedSnapshot.coverageVerifiedAt, snapshotObservedAt: cachedSnapshot.observedAt)
            if result == .healthy { dispatchControl(.recoverySucceeded) }
            else if result == .failed { fail(.inputTapTimeout) }
        }
        if batchOutstanding && completionMutex.try() {
            batchOutstanding = !completedBatch; completionMutex.unlock()
        }
        if !finishing && !manualFinish.pending && recovery.state == .healthy && !batchOutstanding && !pending.actions.isEmpty {
            guard completionMutex.try() else { return }
            completedBatch = false; completionMutex.unlock()
            let batch = pending.take(); batchOutstanding = true
            let epoch = effectEpoch.current
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Even if stop races an outstanding main block, the owner checks
                // its session gate again immediately before every actual effect.
                self.onEffects(batch) { [weak self] in self?.effectEpoch.current == epoch }
                self.completionMutex.lock(); self.completedBatch = true; self.completionMutex.unlock()
            }
        }
        if now - lastMetrics >= 1 {
            metrics.coalescedActions = pending.takeCoalesced()
            let sample = metrics; metrics = .init(); lastMetrics = now
            controls.async { [onMetrics] in onMetrics(sample) }
        }
    }
    private func dispatchControl(_ control: Control) { controls.async { [onControl] in onControl(control) } }
    private func fail(_ cause: FocusLockSafetyStopCause) {
        guard !failedReported else { return }; failedReported = true; finishing = true
        effectEpoch.invalidate(); _ = pending.take()
        dispatchControl(.failed(cause))
    }
}
