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
