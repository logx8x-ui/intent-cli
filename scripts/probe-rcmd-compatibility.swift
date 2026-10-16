import AppKit
import Foundation

/// Read-only production monitor. No event tap, activation, input, writes to app
/// configuration, installation or permission request. Output has no key maps.
private final class ProbeState {
    private let lock = NSLock()
    private var initial: RcmdCompatibilitySnapshot?
    private var updates = 0
    private var invalidated = false
    func prepared(_ snapshot: RcmdCompatibilitySnapshot) { lock.lock(); initial = snapshot; lock.unlock() }
    func snapshot() -> RcmdCompatibilitySnapshot? { lock.lock(); defer { lock.unlock() }; return initial }
    func received() { lock.lock(); updates += 1; lock.unlock() }
    func failed() { lock.lock(); invalidated = true; lock.unlock() }
    func status() -> (Int, Bool) { lock.lock(); defer { lock.unlock() }; return (updates, invalidated) }
}

private let outputLock = NSLock()
private func emit(_ event: String, _ details: [String: Any] = [:]) {
    var record = details
    record["event"] = event; record["readOnly"] = true
    record["utc"] = ISO8601DateFormatter().string(from: Date())
    guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
    data.append(10)
    outputLock.lock(); defer { outputLock.unlock() }
    FileHandle.standardOutput.write(data)
}
private func diagnostic(_ value: RcmdCompatibilityDiagnostic) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

@main struct RcmdCompatibilityProbe {
    static func main() {
        _ = NSApplication.shared
        RcmdCompatibilityMonitor.prepareKeyboardLayout()
        let state = ProbeState()
        let duration = min(300, max(1, CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 90))
        DispatchQueue.global(qos: .utility).async { state.prepared(RcmdCompatibilityMonitor.readCurrent()) }
        let prepareDeadline = Date().addingTimeInterval(5)
        while state.snapshot() == nil && Date() < prepareDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard let initial = state.snapshot() else { emit("prepareTimedOut"); exit(2) }
        var info: [String: Any] = ["compatible": initial.isCompatible, "rcmdPresent": initial.processIdentity != nil,
            "tapIDs": Array(initial.tapIDs.sorted().prefix(16)), "durationSeconds": duration]
        if let pid = initial.processIdentity?.pid { info["pid"] = pid }
        if let revision = initial.keyboardLayoutRevision { info["keyboardLayoutRevision"] = revision }
        emit("baseline", info)
        guard initial.isCompatible else {
            if let failure = initial.diagnostic { emit("baselineUnavailable", diagnostic(failure)) }
            exit(2)
        }
        let monitor = RcmdCompatibilityMonitor(initialSnapshot: initial,
            onSnapshot: { _ in state.received() },
            onDiagnostic: { emit("readUnavailable", diagnostic($0)) },
            onInvalidated: { emit("invalidated", diagnostic($0)); state.failed() })
        monitor.start()
        let began = ProcessInfo.processInfo.systemUptime
        var lastHeartbeat = began
        while ProcessInfo.processInfo.systemUptime - began < duration && !state.status().1 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastHeartbeat >= 10 {
                emit("observing", ["elapsedSeconds": now - began, "snapshotUpdates": state.status().0])
                lastHeartbeat = now
            }
        }
        monitor.stop()
        let result = state.status()
        emit("completed", ["invalidated": result.1, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began,
            "snapshotUpdates": result.0])
        exit(result.1 ? 1 : 0)
    }
}
