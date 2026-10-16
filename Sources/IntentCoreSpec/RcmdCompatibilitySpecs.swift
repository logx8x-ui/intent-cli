import CoreGraphics
import Foundation
import IntentLock

func runRcmdCompatibilitySpecs() throws {
    let identity = RcmdProcessIdentity(pid: 71, launched: 123, version: "3.4.0")
    let status: [String: Any] = ["ok": true, "status": ["pid": 71, "version": "3.4.0",
        "triggerKeysApp": "rcmd", "triggerKeysWindow": "ralt", "triggerKeysStage": "rctrl"]]
    let keys: [String: Any] = ["ok": true, "debug": ["keys": [
        "triggerKeysApp": "rcmd", "triggerKeysWindow": "ralt", "triggerKeysStage": "rctrl",
        "appKeys": [["key": "F", "kind": "static", "detail": "org.mozilla.firefox"],
                    ["key": "C", "kind": "dynamic", "detail": "com.openai.codex"],
                    ["key": "S", "kind": "dynamic", "detail": "com.spotify.client"]],
        "windowKeys": [["key": "D", "kind": "static", "detail": "a window"]],
        "stageKeys": [["key": "W", "kind": "static", "detail": "a stage"]]]]]
    let config: [String: Any] = ["triggerKeys": [4], "windowTriggerKeys": [5], "stageTriggerKeys": [6],
        "enableAssignHotkey": true, "assignKeyTriggerKeys": [4, 5],
        "enableHideOthersHotkey": false, "hideOnFocusTriggerKeys": [4, 0],
        "hijackCommandTab": false, "hijackWindowCycleHotkey": true, "enableWindowCycleKey": true,
        "windowCycleKey": "grave"]
    func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func decode(_ config: [String: Any], status statusOverride: [String: Any]? = nil,
        keys keysOverride: [String: Any]? = nil, process: RcmdProcessIdentity? = nil,
        keyCodes: [String: Int64] = ["f": 3, "c": 8, "s": 1]) throws -> RcmdCompatibilitySnapshot {
        let body = String(decoding: try json(config), as: UTF8.self)
        return try RcmdSnapshotDecoder.decode(statusData: json(statusOverride ?? status), keysData: json(keysOverride ?? keys),
            configData: json(["ok": true, "body": body]), identity: process ?? identity,
            tapIDs: [9], now: 100, keyCodesByCharacter: keyCodes)
    }
    let snapshot = try decode(config)
    try expect(snapshot.isCompatible && snapshot.processIdentity == identity,
        "Live CLI status, keymap and config bind the same exact rcmd process")
    try expect(snapshot.appBundlesByKeyCode[3] == "org.mozilla.firefox"
        && snapshot.appBundlesByKeyCode[8] == "com.openai.codex",
        "Both static and dynamic assignments come from the live keymap")
    let allowed: Set<String> = ["org.mozilla.firefox", "com.openai.codex"]
    let rightCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
    let leftCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
    let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    let rightControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
    var router = RcmdInputRouter()
    try expect(router.route(type: .flagsChanged, keyCode: 54, flags: rightCommand, isRepeat: false,
        now: 100, snapshot: snapshot, allowedBundleIdentifiers: allowed) == .consume,
        "The trigger press is consumed before rcmd can open its switcher")
    try expect(router.route(type: .keyDown, keyCode: 3, flags: rightCommand, isRepeat: false,
        now: 100, snapshot: snapshot, allowedBundleIdentifiers: allowed) == .activate("org.mozilla.firefox"),
        "A mapped allowed app requests Intent-owned exact permitted-window activation")
    try expect(router.route(type: .keyDown, keyCode: 3, flags: rightCommand, isRepeat: true,
        now: 100.01, snapshot: snapshot, allowedBundleIdentifiers: allowed) == .consume,
        "Held shortcuts cannot queue repeated app activations")
    try expect(router.route(type: .flagsChanged, keyCode: 54, flags: [], isRepeat: false,
        now: 100.02, snapshot: snapshot, allowedBundleIdentifiers: allowed) == .pass,
        "Modifier release is delivered even after Intent consumed its press")
    try expect(router.route(type: .keyUp, keyCode: 3, flags: [], isRepeat: false,
        now: 100.03, snapshot: snapshot, allowedBundleIdentifiers: allowed) == .consume,
        "The consumed shortcut owns its key-up after the modifier is released")
    try expect(router.route(type: .keyUp, keyCode: 3, flags: [], isRepeat: false,
        now: 100.04, snapshot: snapshot, allowedBundleIdentifiers: allowed) == .pass,
        "A drained key-up does not suppress later typing")
    for code: Int64 in [1, 7, 48, 50, 53, 27, 24] {
        var input = RcmdInputRouter()
        try expect(input.route(type: .keyDown, keyCode: code, flags: rightCommand, isRepeat: false,
            now: 100.1, snapshot: snapshot, allowedBundleIdentifiers: allowed) == .consume,
            "Excluded/unknown app, fuzzy, cycle, hide and assign inputs cannot reach rcmd")
    }
    for flags in [rightOption, rightControl] {
        var input = RcmdInputRouter()
        try expect(input.route(type: .keyDown, keyCode: 3, flags: flags, isRepeat: false,
            now: 100.1, snapshot: snapshot, allowedBundleIdentifiers: allowed) == .consume,
            "rcmd window and stage paths cannot bypass exact selected-window routing")
    }
    for flags in [leftCommand, CGEventFlags(rawValue: 0)] {
        var input = RcmdInputRouter()
        try expect(input.route(type: .keyDown, keyCode: 3, flags: flags, isRepeat: false,
            now: 100.1, snapshot: snapshot, allowedBundleIdentifiers: allowed) == .pass,
            "Ordinary left Command and unmodified typing remain native")
    }
    var modified = RcmdInputRouter()
    try expect(modified.route(type: .keyDown, keyCode: 3,
        flags: CGEventFlags(rawValue: rightCommand.rawValue | rightOption.rawValue), isRepeat: false,
        now: 100.1, snapshot: snapshot, allowedBundleIdentifiers: allowed) == .consume,
        "Assignment modifiers cannot become an allowed application activation")
    for stale in [snapshot, snapshot.invalidated("topology changed", now: 100)] {
        var input = RcmdInputRouter()
        try expect(input.route(type: .keyDown, keyCode: 3, flags: rightCommand, isRepeat: false,
            now: 104, snapshot: stale, allowedBundleIdentifiers: allowed) == .consume,
            "A stale or invalidated keymap is consumed, never forwarded to rcmd")
    }
    var unrelated = RcmdInputRouter()
    try expect(unrelated.route(type: .keyDown, keyCode: 3, flags: rightCommand, isRepeat: false,
        now: 100, snapshot: .inactive, allowedBundleIdentifiers: allowed) == .pass,
        "Without rcmd running, right Command retains its normal behavior")
    let same = try decode(config)
    try expect(snapshot.remainsCompatible(with: same), "Repeated observations retain stable compatibility")
    let reusedPID = RcmdProcessIdentity(pid: identity.pid, launched: identity.launched + 1, version: identity.version)
    let replacement = try decode(config, process: reusedPID)
    try expect(!snapshot.remainsCompatible(with: replacement), "Reused PID invalidates the original tap ordering")
    var changedConfig = config; changedConfig["hijackCommandTab"] = true
    let changedSnapshot = try decode(changedConfig)
    try expect(!snapshot.remainsCompatible(with: changedSnapshot),
        "Changing trigger-related runtime settings invalidates the session compatibility baseline")
    var unsupportedConfig = config; unsupportedConfig["assignKeyTriggerKeys"] = [0]
    do { _ = try decode(unsupportedConfig); throw SpecFailure(description: "Uncaptured secondary trigger accepted") }
    catch RcmdSnapshotDecoder.Failure.unsupported {}
    var wrongStatus = status
    var body = status["status"] as! [String: Any]; body["pid"] = 72; wrongStatus["status"] = body
    do { _ = try decode(config, status: wrongStatus); throw SpecFailure(description: "Wrong rcmd PID accepted") }
    catch RcmdSnapshotDecoder.Failure.identityChanged {}
    do {
        _ = try RcmdSnapshotDecoder.decode(statusData: Data("{}".utf8), keysData: json(keys),
            configData: Data("{}".utf8), identity: identity, tapIDs: [9], now: 100, keyCodesByCharacter: [:])
        throw SpecFailure(description: "Incomplete live keymap accepted")
    } catch RcmdSnapshotDecoder.Failure.malformed {}
    let unknownLayout = try decode(config, keyCodes: [:])
    var layoutRouter = RcmdInputRouter()
    try expect(layoutRouter.route(type: .keyDown, keyCode: 3, flags: rightCommand, isRepeat: false,
        now: 100, snapshot: unknownLayout, allowedBundleIdentifiers: allowed) == .consume,
        "An unresolved keyboard layout never guesses an allowed app from a US keycode")
    var readRecovery = RcmdReadRecoveryPolicy()
    try expect(readRecovery.unavailable(now: 1) && !readRecovery.expired(now: 2.99),
        "One stalled rcmd CLI read suspends mappings instead of immediately releasing the intention")
    try expect(readRecovery.unavailable(now: 2.9) && readRecovery.expired(now: 3),
        "Repeated unavailable reads cannot restart the two-second compatibility deadline")
    try expect(!readRecovery.verified(now: 3.01), "A late reply cannot revive expired compatibility")
    var recoveredRead = RcmdReadRecoveryPolicy()
    _ = recoveredRead.unavailable(now: 1)
    try expect(recoveredRead.verified(now: 2) && !recoveredRead.expired(now: 100),
        "A matching original process/keymap can recover before the bounded deadline")
}
