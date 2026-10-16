import Foundation

@main
enum EnforcementHealthSpec {
    static func main() throws {
        func initial() -> FocusEnforcementHealth {
            .init(accessMode: "whitelist", requiresEnforcement: true, hideDistractions: true,
                  selectedWindowGroupCount: 1, now: Date(timeIntervalSinceReferenceDate: 10))
        }
        for cause in [FocusLockSafetyStopCause.inputTapTimeout, .inputTapDisabled,
                      .selectedWindowRecoveryUnavailable, .browserWindowEnforcementFailure, .nativeWindowEnforcementFailure,
                      .accessibilityPermissionRequired, .inputTapUnavailable] {
            var health = initial()
            health.apply(.starting); health.apply(.inputTapInstalled); health.apply(.ready)
            health.apply(.safetyStopped(cause)); health.apply(.completed)
            health.apply(.ready); health.apply(.blockedActivation)
            precondition(health.phase == .stopped && health.finish == .safety && health.safetyStopCause == cause,
                         "Cleanup or delayed readiness must preserve the actual failure")
            precondition(health.blockedActivationCount == 0, "Late enforcement must not affect a stopped occurrence")
            precondition(health.inputTapTimeoutCount == (cause == .inputTapTimeout ? 1 : 0))
            precondition(health.inputTapDisabledCount == (cause == .inputTapDisabled ? 1 : 0))
        }
        for reason in [FocusEnforcementHealth.Finish.manual, .expiry] {
            var health = initial(); health.apply(.ready); health.apply(.finished(reason))
            health.apply(.safetyStopped(.inputTapTimeout)); health.apply(.completed)
            precondition(health.finish == reason && health.safetyStopCause == nil,
                         "A delayed tap failure must not turn a completed intention into an error")
        }
        var recovering = initial()
        recovering.apply(.ready); recovering.apply(.inputTapRecoveryBegan)
        precondition(recovering.phase == .recovering && recovering.inputTapTimeoutCount == 1)
        recovering.apply(.inputTapRecoveryBegan)
        precondition(recovering.inputRecoveryAttempts == 1, "Duplicate signals cannot inflate one repair attempt")
        recovering.apply(.ready)
        precondition(recovering.phase == .recovering, "Late startup readiness cannot approve an input repair")
        recovering.apply(.inputTapRecoverySucceeded)
        precondition(recovering.phase == .enforcing && recovering.inputRecoverySuccesses == 1)
        recovering.apply(.safetyStopped(.inputTapTimeout))
        precondition(recovering.inputTapTimeoutCount == 2, "A later timeout remains a separate failure")
        var failedRecovery = initial()
        failedRecovery.apply(.ready); failedRecovery.apply(.inputTapRecoveryBegan)
        failedRecovery.apply(.safetyStopped(.inputTapTimeout))
        precondition(failedRecovery.inputTapTimeoutCount == 1, "Failed repair must not count one timeout twice")
        failedRecovery.apply(.inputTapRecoverySucceeded)
        precondition(failedRecovery.phase == .stopped, "Late successful repair cannot resurrect an ended session")
        var metrics = initial()
        metrics.apply(.inputSample(durationMicroseconds: 120, snapshotAgeMilliseconds: 25))
        metrics.apply(.inputSample(durationMicroseconds: .infinity, snapshotAgeMilliseconds: .nan))
        metrics.apply(.inputQueueDepth(3)); metrics.apply(.inputQueueDepth(1)); metrics.apply(.inputWorkCoalesced)
        precondition(metrics.maxCallbackMicroseconds == 120 && metrics.maxSnapshotAgeMilliseconds == 25)
        precondition(metrics.maxPendingInputActions == 3 && metrics.coalescedInputActions == 1)
        metrics.apply(.inputBatch(samples: 10_000, maxDurationMicroseconds: 220, maxSnapshotAgeMilliseconds: 34,
            maxPendingActions: 4, coalescedActions: 9_000, schedulingDelayMilliseconds: 18))
        precondition(metrics.inputCallbackCount == 10_002 && metrics.maxInputSchedulingDelayMilliseconds == 18)
        precondition(metrics.maxCallbackMicroseconds == 220 && metrics.coalescedInputActions == 9_001)
        let sink = FocusEnforcementDiagnosticSink()
        let previous = sink.begin(initial())
        sink.record(.starting, owner: previous); sink.record(.ready, owner: previous)
        let current = sink.begin(initial())
        sink.record(.safetyStopped(.inputTapTimeout), owner: previous)
        sink.record(.completed, owner: previous)
        precondition(sink.snapshot()?.phase == .prepared && sink.snapshot()?.safetyStopCause == nil,
                     "Old teardown must not overwrite the new occurrence")
        sink.record(.starting, owner: current); sink.record(.inputTapInstalled, owner: current)
        sink.record(.blockedClick, owner: current); sink.record(.blockedActivation, owner: current)
        sink.record(.ready, owner: current)
        precondition(sink.snapshot()?.blockedClickCount == 1 && sink.snapshot()?.blockedActivationCount == 1)
        let encoded = try JSONEncoder().encode(sink.snapshot()!)
        let decoded = try JSONDecoder().decode(FocusEnforcementHealth.self, from: encoded)
        precondition(decoded == sink.snapshot()!)
        let keys = Set((try JSONSerialization.jsonObject(with: encoded) as! [String: Any]).keys)
        let allowedKeys: Set<String> = ["schemaVersion", "phase", "accessMode", "requiresEnforcement",
            "hideDistractions", "selectedWindowGroupCount", "startedAt", "updatedAt", "becameReady",
            "inputTapInstalled", "inputTapTimeoutCount", "inputTapDisabledCount", "blockedActivationCount",
            "blockedClickCount", "finish", "safetyStopCause", "inputRecoveryAttempts", "inputRecoverySuccesses",
            "inputCallbackCount", "maxCallbackMicroseconds", "maxSnapshotAgeMilliseconds", "maxInputSchedulingDelayMilliseconds", "maxPendingInputActions", "coalescedInputActions"]
        precondition(keys.isSubset(of: allowedKeys), "Diagnostics must contain only counts, flags and typed lifecycle state")
        for _ in 0..<1_000_005 { sink.record(.blockedClick, owner: current) }
        precondition(sink.snapshot()?.blockedClickCount == 1_000_000, "Long runs keep counters bounded")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intent-health-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("health.json")
        let persisted = FocusEnforcementDiagnosticSink(fileURL: file)
        for index in 0..<25 {
            var item = initial(); item.selectedWindowGroupCount = index
            let owner = persisted.begin(item)
            persisted.record(.safetyStopped(.inputTapTimeout), owner: owner)
        }
        let historyURL = directory.appendingPathComponent("health.history.json")
        let deadline = Date().addingTimeInterval(3)
        var history: [[String: Any]] = []
        repeat {
            Thread.sleep(forTimeInterval: 0.02)
            if let data = try? Data(contentsOf: historyURL),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { history = decoded }
        } while (history.last?["health"] as? [String: Any])?["selectedWindowGroupCount"] as? Int != 24 && Date() < deadline
        precondition(history.count == 20, "Diagnostics retain a bounded set of separate occurrences")
        precondition((history.first?["health"] as? [String: Any])?["selectedWindowGroupCount"] as? Int == 5)
        precondition((history.last?["health"] as? [String: Any])?["safetyStopCause"] as? String == "inputTapTimeout")
        let attributes = try FileManager.default.attributesOfItem(atPath: historyURL.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var pending: [() -> Void] = []
        var recoveries = 0
        let inputRecovery = FocusInputRecoveryQueue(enqueue: { pending.append($0) })
        for _ in 0..<1_000 { inputRecovery.request { recoveries += 1 } }
        precondition(pending.count == 1 && recoveries == 0, "Recovery must never run inside the input callback")
        pending.removeFirst()()
        precondition(recoveries == 1, "Repeated rejected input must share one recovery")
        inputRecovery.request { recoveries += 1 }
        precondition(pending.count == 1, "A later rejection must remain recoverable")
        inputRecovery.stop()
        pending.removeFirst()()
        inputRecovery.request { recoveries += 1 }
        precondition(recoveries == 1 && pending.isEmpty, "Stopping must fence pending and subsequent recovery")
        let windowRecovery = FocusSelectedWindowRecoveryPolicy()
        precondition(windowRecovery.beginAttempt(now: 10))
        precondition(windowRecovery.failed(now: 10.03, resources: .present) == .retryLater,
                     "A failed raise with still-live selected work must retain enforcement")
        for step in 1..<15 {
            precondition(!windowRecovery.beginAttempt(now: 10 + Double(step) / 100),
                         "A 40 ms focus timer must not repeat blocking AX recovery on every tick")
        }
        precondition(windowRecovery.beginAttempt(now: 10.16))
        windowRecovery.recovered()
        precondition(windowRecovery.beginAttempt(now: 20))
        precondition(windowRecovery.failed(now: 23.01, resources: .present) == .safetyStop,
                     "Unrecoverable live work has a bounded safety fallback")
        precondition(windowRecovery.failed(now: 23.02, resources: .closed) == .awaitNormalCompletion,
                     "Confirmed exhaustion belongs to the ordinary lifetime monitor, never a safety stop")
        let uncertainRecovery = FocusSelectedWindowRecoveryPolicy()
        precondition(uncertainRecovery.beginAttempt(now: 30))
        precondition(uncertainRecovery.failed(now: 30.1, resources: .unknown) == .retryLater,
                     "Unknown native inventory must not establish closure")
        precondition(uncertainRecovery.failed(now: 33.1, resources: .unknown) == .safetyStop)
        let effects = DeferredSessionActionGate()
        let captured = effects.token
        var refocusEffects = 0
        uncertainRecovery.stop(); effects.invalidate()
        precondition(!uncertainRecovery.beginAttempt(now: 40))
        precondition(uncertainRecovery.failed(now: 40, resources: .present) == .cancelled)
        effects.perform(ifCurrent: captured) { refocusEffects += 1 }
        precondition(refocusEffects == 0,
                     "Even a retry which began before Finish cannot activate after cancellation")
        print("PASS enforcement health: typed stop causes, manual/expiry race, stale occurrence fence, bounded private schema, deferred/coalesced/cancelled input recovery, bounded selected-window retries and normal closure")
    }
}
