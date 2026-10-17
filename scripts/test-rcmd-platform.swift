import AppKit
import CoreGraphics
import Foundation

private struct PlatformFailure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PlatformFailure(description: message) }
}

private final class Completion {
    private let lock = NSLock()
    private var value: Result<Void, Error>?
    func finish(_ result: Result<Void, Error>) { lock.lock(); value = result; lock.unlock() }
    var result: Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Pump the real main runloop; never wait on a semaphore that prevents Carbon's
/// required main-thread work. A timeout fails the spec instead of hanging QA.
private func background(_ work: @escaping () throws -> Void) throws {
    let completed = Completion()
    DispatchQueue.global(qos: .userInitiated).async { completed.finish(Result { try work() }) }
    let deadline = Date(timeIntervalSinceNow: 5)
    while completed.result == nil && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    guard let result = completed.result else { throw PlatformFailure(description: "Background platform check timed out") }
    try result.get()
}

/// Controlled process/tap observations exercise the production monitor without
/// creating a tap, changing rcmd, touching a daily ledger, or sending input.
private final class ProcessFixture {
    let root: URL
    let identity: RcmdProcessIdentity
    var listed: [Int32] = [71]
    var owners: [Int32]? = [71]
    var processes: [Int32: RcmdKernelProcessObservation] = [:]
    var inventory = RcmdTapInventory(available: true, ids: [9])
    var snapshots: [RcmdCompatibilitySnapshot] = []
    var failures: [RcmdCompatibilityDiagnostic] = []
    var diagnostics: [RcmdCompatibilityDiagnostic] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("intent-rcmd-fixture-\(UUID().uuidString).app")
        let support = root.appendingPathComponent("Contents/SharedSupport")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let cli = support.appendingPathComponent("rcmdCLI")
        try Data().write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        identity = .init(pid: 71, launched: 123, version: "3.4.0", executablePath: root.appendingPathComponent("Contents/MacOS/rcmd").path)
        processes[71] = .running(.init(identity: identity, bundleURL: root))
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    var inspector: RcmdProcessInspector {
        .init(applicationPIDs: { self.listed }, kernelProcess: { self.processes[$0] ?? .absent }, tapOwnerPIDs: { self.owners })
    }
    func read(expected: RcmdProcessIdentity?) -> RcmdCompatibilitySnapshot {
        RcmdCompatibilityMonitor.readCurrent(expected: expected, processInspector: inspector,
            inventoryReader: { _ in self.inventory }, cliReader: { _, arguments in
                let object: [String: Any]
                if arguments.first == "status" {
                    object = ["ok": true, "status": ["pid": 71, "version": "3.4.0", "triggerKeysApp": "rcmd",
                        "triggerKeysWindow": "ralt", "triggerKeysStage": "rctrl"]]
                } else if arguments.first == "app" {
                    object = ["ok": true, "debug": ["keys": ["triggerKeysApp": "rcmd", "triggerKeysWindow": "ralt",
                        "triggerKeysStage": "rctrl", "appKeys": [["key": "F", "kind": "static", "detail": "org.example.allowed"]],
                        "windowKeys": [], "stageKeys": []]]]
                } else {
                    let config: [String: Any] = ["triggerKeys": [4], "windowTriggerKeys": [5], "stageTriggerKeys": [6],
                        "enableAssignHotkey": false, "assignKeyTriggerKeys": [4, 5], "enableHideOthersHotkey": false,
                        "hideOnFocusTriggerKeys": [4, 0], "hijackCommandTab": false,
                        "hijackWindowCycleHotkey": false, "enableWindowCycleKey": false, "windowCycleKey": "grave"]
                    object = ["ok": true, "body": String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)]
                }
                return try JSONSerialization.data(withJSONObject: object)
            })
    }
    func monitor(_ baseline: RcmdCompatibilitySnapshot) -> RcmdCompatibilityMonitor {
        .init(initialSnapshot: baseline, onSnapshot: { self.snapshots.append($0) },
            onDiagnostic: { self.diagnostics.append($0) }, onInvalidated: { self.failures.append($0) },
            processInspector: inspector, inventoryReader: { _ in self.inventory }, snapshotReader: { self.read(expected: $0) })
    }
}

private func processDiscoveryRegressions() throws {
    let fixture = try ProcessFixture()
    let baseline = fixture.read(expected: nil)
    try require(baseline.isCompatible, "Fixture must start from a fully decoded verified configuration (\(baseline.statusReason ?? "unknown"))")
    let monitor = fixture.monitor(baseline)
    fixture.listed = []
    try require(monitor.verifyTopology() && fixture.failures.isEmpty,
        "Empty AppKit enumeration must not report processTerminated while the exact kernel lifetime/path and tap remain")
    let reverified = fixture.read(expected: baseline.processIdentity)
    try require(baseline.remainsCompatible(with: reverified),
        "The complete CLI reread must also survive AppKit disappearance, rather than returning inactive")
    try require(fixture.read(expected: nil).isCompatible && fixture.read(expected: nil).processIdentity == baseline.processIdentity,
        "Startup discovers a live rcmd keyboard-tap owner even when AppKit returns no applications")
    fixture.listed = [71]
    try require(monitor.verifyTopology(notificationPID: 71) && fixture.failures.isEmpty,
        "A stale termination notification must reverify the still-live original process instead of stopping")
    try require(monitor.verifyTopology(notificationPID: 70) && fixture.failures.isEmpty,
        "A stale notification for a dead previous PID cannot invalidate the original process")
    fixture.owners = [71, 80]; fixture.processes[80] = .otherProcess
    try require(monitor.verifyTopology() && fixture.failures.isEmpty,
        "An unrelated positively identified unbundled keyboard-tap owner must not create a false rcmd stop")
    fixture.owners = [71]
    switch RcmdProcessInspector.live.kernelProcess(ProcessInfo.processInfo.processIdentifier) {
    case .otherProcess: break
    default: throw PlatformFailure(description: "The actual unbundled regression executable must be identified as non-rcmd")
    }
    let metadataURL = fixture.root.appendingPathComponent("Contents/Info.plist")
    for version in ["3.4.0", "3.4.1"] {
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.lowtechguys.rcmd",
            "CFBundleShortVersionString": version], format: .xml, options: 0)
        try data.write(to: metadataURL)
        try require(RcmdProcessInspector.readBundleMetadata(fixture.root)?["CFBundleShortVersionString"] as? String == version,
            "Process identity must read replaced Info.plist values without Bundle cache reuse")
    }
    try Data(repeating: 32, count: 262_145).write(to: metadataURL)
    try require(RcmdProcessInspector.readBundleMetadata(fixture.root) == nil,
        "Unbounded bundle metadata must not be read as a verified process identity")

    fixture.processes[71] = .unavailable
    try require(!monitor.verifyTopology() && fixture.failures.isEmpty
        && fixture.diagnostics.last?.reason == .processIdentityUnavailable
        && fixture.snapshots.last?.isCompatible == false && fixture.snapshots.last?.appBundlesByKeyCode.isEmpty == true,
        "Unknown kernel reads suspend mapped activations inside the bounded verification deadline; they are not exits")
    fixture.processes[71] = .running(.init(identity: fixture.identity, bundleURL: fixture.root))
    monitor.completeRead(reverified)
    try require(fixture.snapshots.last?.isCompatible == false,
        "A reader callback older than the unknown observation cannot restore stale mapped activations")
    monitor.completeRead(fixture.read(expected: baseline.processIdentity))
    try require(fixture.snapshots.last?.isCompatible == true && fixture.failures.isEmpty,
        "Only a fresh full process/tap/config/layout read can restore mapped activations")

    let changed: [(RcmdKernelProcessObservation, RcmdCompatibilityFailure, String)] = [
        (.running(.init(identity: .init(pid: 71, launched: 124, version: "3.4.0", executablePath: fixture.identity.executablePath), bundleURL: fixture.root)), .processIdentityChanged, "PID reuse"),
        (.running(.init(identity: .init(pid: 71, launched: 123, version: "3.4.0", executablePath: "/different/rcmd"), bundleURL: fixture.root)), .processIdentityChanged, "executable replacement"),
        (.running(.init(identity: .init(pid: 71, launched: 123, version: "3.4.1", executablePath: fixture.identity.executablePath), bundleURL: fixture.root)), .processIdentityChanged, "version replacement"),
        (.otherProcess, .processIdentityChanged, "positive different process"), (.absent, .processTerminated, "kernel-confirmed exit")
    ]
    for (observation, reason, label) in changed {
        let next = fixture.monitor(baseline); fixture.processes[71] = observation
        try require(!next.verifyTopology() && fixture.failures.last?.reason == reason, "\(label) must invalidate the original identity")
    }
    fixture.processes[71] = .running(.init(identity: fixture.identity, bundleURL: fixture.root))
    let newProcess = RcmdObservedProcess(identity: .init(pid: 72, launched: 200, version: "3.4.0", executablePath: "/copy/rcmd"), bundleURL: fixture.root)
    fixture.processes[72] = .running(newProcess); fixture.listed = []; fixture.owners = [71, 72]
    let extra = fixture.monitor(baseline)
    try require(!extra.verifyTopology() && fixture.failures.last?.reason == .processIdentityChanged,
        "A second keyboard-tap owner cannot be hidden by the same missing AppKit enumeration")
    fixture.owners = [71]
    let notified = fixture.monitor(baseline)
    try require(!notified.verifyTopology(notificationPID: 72) && fixture.failures.last?.reason == .processIdentityChanged,
        "A positively live newly launched rcmd invalidates even before AppKit enumeration contains it")
    fixture.processes[72] = .absent
    let extraTap = fixture.monitor(baseline); fixture.inventory = .init(available: true, ids: [9, 10])
    try require(!extraTap.verifyTopology() && fixture.failures.last?.reason == .tapIDsChanged,
        "A new tap owned by the original process still invalidates its capture ordering")
    fixture.inventory = .init(available: true, ids: [9], disabled: [9])
    let disabled = fixture.monitor(baseline)
    try require(!disabled.verifyTopology() && fixture.failures.last?.reason == .tapDisabled,
        "Kernel identity continuity cannot excuse a disabled original tap")
    fixture.owners = nil
    try require(!fixture.read(expected: nil).isCompatible,
        "Unknown global tap inventory cannot certify inactive rcmd during empty AppKit discovery")
    fixture.owners = [71]; fixture.processes[71] = .unavailable
    try require(!fixture.read(expected: nil).isCompatible,
        "Missing metadata for a discovered rcmd candidate cannot certify an inactive process")
    print("rcmd empty-AppKit discovery, stale lifecycle notice, queued-read ordering and positive-change regressions passed")
}

@main
struct RcmdPlatformSpec {
    static func main() {
        do {
            _ = NSApplication.shared
            // Exercise worker-first preparation too: it must schedule main work,
            // never enter TSMCurrentAsciiCapableKeyboardLayoutInputSourceRefCreate.
            try background { RcmdCompatibilityMonitor.prepareKeyboardLayout() }
            RcmdCompatibilityMonitor.prepareKeyboardLayout()
            guard let initial = RcmdKeyboardLayoutCache.shared.snapshot else {
                throw PlatformFailure(description: "Main-thread keyboard-layout capture did not complete")
            }
            try require(!initial.keyCodesByCharacter.isEmpty, "Real Carbon layout must resolve characters")
            try processDiscoveryRegressions()
            try background {
                try require(!Thread.isMainThread, "Actual platform regression must use a worker")
                for _ in 0..<1_000 {
                    try require(RcmdKeyboardLayoutCache.shared.snapshot == initial, "Worker reads must use the captured value")
                }
                // This exact live production call previously crashed the installed
                // app on a Carbon main-thread assertion. No event tap is created.
                let live = RcmdCompatibilityMonitor.readCurrent()
                if live.isCompatible, live.processIdentity != nil {
                    try require(live.keyboardLayoutRevision == initial.revision,
                        "Live CLI mapping must bind the captured keyboard generation")
                }
                print("Background readCurrent returned; rcmd present=\(live.processIdentity != nil), compatible=\(live.isCompatible)")
            }
            let old = RcmdCompatibilitySnapshot(processIdentity: .init(pid: 1, launched: 1, version: "3.4.0"),
                observedAtUptime: 1, isCompatible: true, statusReason: nil,
                appTrigger: RcmdModifierChord(description: "rcmd"), blockedTriggers: [RcmdModifierChord(description: "rcmd")!],
                appBundlesByKeyCode: [3: "allowed"], tapIDs: [1], capturesCommandGrave: false,
                configurationFingerprint: "fixture", keyboardLayoutRevision: initial.revision)
            let rightCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
            try background {
                RcmdKeyboardLayoutCache.shared.invalidateAndRefresh()
                try require(!RcmdKeyboardLayoutCache.shared.isCurrent(initial.revision),
                    "Input-source notification must revoke the old map before refresh")
                var router = RcmdInputRouter()
                try require(router.route(type: .keyDown, keyCode: 3, flags: rightCommand, isRepeat: false,
                    now: 1, snapshot: old, allowedBundleIdentifiers: ["allowed"]) == .consume,
                    "A queued policy cannot authorize an app using a revoked layout")
            }
            let deadline = Date(timeIntervalSinceNow: 2)
            while RcmdKeyboardLayoutCache.shared.snapshot == nil && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            guard let refreshed = RcmdKeyboardLayoutCache.shared.snapshot else {
                throw PlatformFailure(description: "Layout refresh did not complete")
            }
            try require(refreshed.revision != initial.revision, "Refresh must publish a new layout generation")
            try background {
                let live = RcmdCompatibilityMonitor.readCurrent()
                if live.isCompatible, live.processIdentity != nil {
                    try require(live.keyboardLayoutRevision == refreshed.revision,
                        "Recovery requires live rcmd data coherent with the refreshed layout")
                }
            }
            print("rcmd actual-platform background discovery and keyboard-layout invalidation passed")
        } catch {
            fputs("rcmd platform regression failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
