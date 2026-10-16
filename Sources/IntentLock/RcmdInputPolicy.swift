import Foundation
import CoreGraphics

/// A process name or PID alone cannot identify a switcher's lifetime.
public struct RcmdProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let launched: TimeInterval
    public let version: String
    public init(pid: Int32, launched: TimeInterval, version: String) {
        self.pid = pid; self.launched = launched; self.version = version
    }
}

public struct RcmdModifierChord: Equatable, Sendable {
    public let rawMask: UInt64
    public init?(description: String) {
        let tokens = description.lowercased().split(whereSeparator: { " +,|[]".contains($0) }).map(String.init)
        guard !tokens.isEmpty, tokens.allSatisfy({ Self.masks[$0] != nil }) else { return nil }
        rawMask = tokens.reduce(0) { $0 | Self.masks[$1]! }
    }
    public func matches(_ flags: CGEventFlags) -> Bool { flags.rawValue & rawMask == rawMask }
    public var hasRightModifier: Bool { rawMask & Self.rightMask != 0 }
    public static let rightMask: UInt64 = 0x10 | 0x40 | 0x2000 | 0x4
    // Device-dependent bits distinguish right Command from ordinary left Command.
    private static let masks: [String: UInt64] = [
        "lcmd": 0x8, "rcmd": 0x10, "lalt": 0x20, "ralt": 0x40,
        "lctrl": 0x1, "rctrl": 0x2000, "lshift": 0x2, "rshift": 0x4,
        "fn": 0x800000
    ]
    static let modifierKeyMasks: [Int64: UInt64] = [
        55: 0x8, 54: 0x10, 58: 0x20, 61: 0x40, 59: 0x1, 62: 0x2000,
        56: 0x2, 60: 0x4, 63: 0x800000
    ]
}

/// Immutable data published by a worker. No CLI, AppKit or window query occurs
/// when deciding whether a key may reach the third-party switcher.
public struct RcmdCompatibilitySnapshot: Equatable, Sendable {
    public let processIdentity: RcmdProcessIdentity?
    public let observedAtUptime: TimeInterval
    public let isCompatible: Bool
    public let statusReason: String?
    public let appTrigger: RcmdModifierChord?
    public let blockedTriggers: [RcmdModifierChord]
    public let appBundlesByKeyCode: [Int64: String]
    public let tapIDs: Set<UInt32>
    public let capturesCommandGrave: Bool
    /// The configuration fingerprint excludes changing app/key use counts.
    public let configurationFingerprint: String
    public let retryableFailure: Bool
    public let keyboardLayoutRevision: UInt64?
    public let diagnostic: RcmdCompatibilityDiagnostic?
    public static let maximumAge: TimeInterval = 3
    public static let inactive = Self(processIdentity: nil, observedAtUptime: 0,
        isCompatible: true, statusReason: nil, appTrigger: nil, blockedTriggers: [],
        appBundlesByKeyCode: [:], tapIDs: [], capturesCommandGrave: false, configurationFingerprint: "")

    public init(processIdentity: RcmdProcessIdentity?, observedAtUptime: TimeInterval, isCompatible: Bool,
        statusReason: String?, appTrigger: RcmdModifierChord?, blockedTriggers: [RcmdModifierChord],
        appBundlesByKeyCode: [Int64: String], tapIDs: Set<UInt32>, capturesCommandGrave: Bool,
        configurationFingerprint: String, retryableFailure: Bool = false, keyboardLayoutRevision: UInt64? = nil,
        diagnostic: RcmdCompatibilityDiagnostic? = nil) {
        self.processIdentity = processIdentity; self.observedAtUptime = observedAtUptime
        self.isCompatible = isCompatible; self.statusReason = statusReason; self.appTrigger = appTrigger
        self.blockedTriggers = blockedTriggers; self.appBundlesByKeyCode = appBundlesByKeyCode
        self.tapIDs = tapIDs; self.capturesCommandGrave = capturesCommandGrave
        self.configurationFingerprint = configurationFingerprint
        self.retryableFailure = retryableFailure
        self.keyboardLayoutRevision = keyboardLayoutRevision
        self.diagnostic = diagnostic
    }

    public func invalidated(_ reason: String, now: TimeInterval) -> Self {
        .init(processIdentity: processIdentity, observedAtUptime: now, isCompatible: false,
            statusReason: reason, appTrigger: appTrigger, blockedTriggers: blockedTriggers,
            appBundlesByKeyCode: [:], tapIDs: tapIDs, capturesCommandGrave: capturesCommandGrave,
            configurationFingerprint: configurationFingerprint, keyboardLayoutRevision: keyboardLayoutRevision,
            diagnostic: diagnostic)
    }

    func usingKeyboardLayout(revision: UInt64) -> Self {
        .init(processIdentity: processIdentity, observedAtUptime: observedAtUptime, isCompatible: isCompatible,
            statusReason: statusReason, appTrigger: appTrigger, blockedTriggers: blockedTriggers,
            appBundlesByKeyCode: appBundlesByKeyCode, tapIDs: tapIDs, capturesCommandGrave: capturesCommandGrave,
            configurationFingerprint: configurationFingerprint, retryableFailure: retryableFailure,
            keyboardLayoutRevision: revision, diagnostic: diagnostic)
    }

    public func remainsCompatible(with current: Self) -> Bool {
        isCompatible && current.isCompatible && processIdentity == current.processIdentity
            && tapIDs == current.tapIDs && configurationFingerprint == current.configurationFingerprint
    }

    /// Explains the existing compatibility decision without changing it.
    public func incompatibilityReason(with current: Self) -> RcmdCompatibilityFailure? {
        if let reason = current.diagnostic?.reason { return reason }
        if processIdentity == nil && current.processIdentity != nil { return .processStarted }
        if processIdentity != nil && current.processIdentity == nil { return .processTerminated }
        if processIdentity != current.processIdentity { return .processIdentityChanged }
        if tapIDs != current.tapIDs { return .tapIDsChanged }
        if configurationFingerprint != current.configurationFingerprint { return .configurationChanged }
        return remainsCompatible(with: current) ? nil : .schemaUnsupported
    }
}

public enum RcmdInputRoute: Equatable { case pass, consume, activate(String) }

/// A stalled CLI may suspend mapped shortcuts briefly without releasing an
/// otherwise healthy intention. Positive process/configuration changes bypass
/// this policy and invalidate compatibility immediately.
public struct RcmdReadRecoveryPolicy {
    public private(set) var unavailableSince: TimeInterval?
    public init() {}
    public func expired(now: TimeInterval) -> Bool {
        unavailableSince.map { now < $0 || now - $0 >= 2 } ?? false
    }
    public mutating func unavailable(now: TimeInterval) -> Bool {
        unavailableSince = unavailableSince ?? now
        return !expired(now: now)
    }
    public mutating func verified(now: TimeInterval) -> Bool {
        guard !expired(now: now) else { return false }
        unavailableSince = nil
        return true
    }
}

/// Owned exclusively by the event-tap thread, including key-up suppression.
public struct RcmdInputRouter {
    private var consumedKeys: Set<Int64> = []
    public init() {}

    public mutating func route(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool,
        now: TimeInterval, snapshot: RcmdCompatibilitySnapshot,
        allowedBundleIdentifiers: Set<String>) -> RcmdInputRoute {
        if type == .keyUp { return consumedKeys.remove(keyCode) != nil ? .consume : .pass }
        guard snapshot.processIdentity != nil else { return .pass }
        let fresh = snapshot.isCompatible && now >= snapshot.observedAtUptime
            && now - snapshot.observedAtUptime <= RcmdCompatibilitySnapshot.maximumAge
            && (snapshot.keyboardLayoutRevision.map { RcmdKeyboardLayoutCache.shared.isCurrent($0) } ?? true)
        let matched = snapshot.blockedTriggers.contains { $0.matches(flags) }
        let uncertainRightTrigger = !fresh && flags.rawValue & RcmdModifierChord.rightMask != 0
        let commandGrave = snapshot.capturesCommandGrave && flags.contains(.maskCommand) && keyCode == 50

        if type == .flagsChanged {
            // Always deliver releases. Consuming a release can leave a lower
            // tap or the foreground app believing Command is still held.
            guard let changedMask = RcmdModifierChord.modifierKeyMasks[keyCode],
                  flags.rawValue & changedMask != 0 else { return .pass }
            return matched || uncertainRightTrigger ? .consume : .pass
        }
        guard type == .keyDown else { return .pass }
        // A repeated down belongs to its original swallowed press even when
        // modifiers or the configuration change before the key is released.
        if consumedKeys.contains(keyCode) { return .consume }
        guard matched || uncertainRightTrigger || commandGrave else { return .pass }
        consumedKeys.insert(keyCode)
        guard fresh, !isRepeat, !commandGrave,
              let appTrigger = snapshot.appTrigger, appTrigger.matches(flags),
              // Modified commands (assign, hide, fuzzy/stage/window actions)
              // must never accidentally become an ordinary app activation.
              flags.rawValue & Self.sidedModifiers == appTrigger.rawMask,
              let bundle = snapshot.appBundlesByKeyCode[keyCode],
              allowedBundleIdentifiers.contains(bundle) else { return .consume }
        return .activate(bundle)
    }

    private static let sidedModifiers: UInt64 = 0x8 | 0x10 | 0x20 | 0x40 | 0x1 | 0x2000 | 0x2 | 0x4 | 0x800000
}

public enum RcmdSnapshotDecoder {
    public enum Failure: Error { case malformed, unsupported, identityChanged, ambiguousKey }

    public static func decode(statusData: Data, keysData: Data, configData: Data,
        identity: RcmdProcessIdentity, tapIDs: Set<UInt32>, now: TimeInterval,
        keyCodesByCharacter: [String: Int64]) throws -> RcmdCompatibilitySnapshot {
        let statusRoot = try object(statusData), keysRoot = try object(keysData), configRoot = try object(configData)
        guard statusRoot["ok"] as? Bool == true, keysRoot["ok"] as? Bool == true,
              configRoot["ok"] as? Bool == true,
              let status = statusRoot["status"] as? [String: Any],
              let debug = keysRoot["debug"] as? [String: Any], let keys = debug["keys"] as? [String: Any],
              let body = configRoot["body"] as? String, let bodyData = body.data(using: .utf8) else { throw Failure.malformed }
        let config = try object(bodyData)
        guard status["pid"] as? Int == Int(identity.pid),
              status["version"] as? String == identity.version else { throw Failure.identityChanged }
        // This exact schema/trigger contract is qualified against rcmd 3.4.0.
        guard identity.version == "3.4.0", !tapIDs.isEmpty else { throw Failure.unsupported }
        let names = ["triggerKeysApp", "triggerKeysWindow", "triggerKeysStage"]
        var descriptions: [String] = [], triggers: [RcmdModifierChord] = []
        for name in names {
            guard let value = keys[name] as? String, status[name] as? String == value,
                  let trigger = RcmdModifierChord(description: value), trigger.hasRightModifier else { throw Failure.unsupported }
            descriptions.append(value); triggers.append(trigger)
        }
        guard let rawAppKeys = keys["appKeys"] as? [[String: Any]],
              keys["windowKeys"] is [[String: Any]], keys["stageKeys"] is [[String: Any]] else { throw Failure.malformed }
        var bundles: [Int64: String] = [:]
        for entry in rawAppKeys {
            guard let character = entry["key"] as? String, let bundle = entry["detail"] as? String,
                  let kind = entry["kind"] as? String, ["static", "dynamic"].contains(kind),
                  !bundle.isEmpty, bundle.contains("."), !bundle.contains(where: { $0.isWhitespace || $0 == "/" }),
                  character.count == 1 else { throw Failure.malformed }
            // An untranslatable layout key is consumed but cannot activate.
            guard let code = keyCodesByCharacter[character.lowercased()] else { continue }
            guard bundles[code] == nil else { throw Failure.ambiguousKey }
            bundles[code] = bundle
        }
        let primaryNames = ["triggerKeys", "windowTriggerKeys", "stageTriggerKeys"]
        let primary = try primaryNames.map { name -> Set<Int> in
            guard let values = config[name] as? [Int], !values.isEmpty else { throw Failure.malformed }
            return Set(values)
        }
        // The CLI exports modifier enums as numbers. We need not guess their
        // enum values: secondary triggers must include a captured primary set.
        for (enabled, name) in [("enableAssignHotkey", "assignKeyTriggerKeys"),
                                ("enableHideOthersHotkey", "hideOnFocusTriggerKeys")] {
            guard let isEnabled = config[enabled] as? Bool else { throw Failure.malformed }
            if isEnabled {
                guard let values = config[name] as? [Int], primary.contains(where: { $0.isSubset(of: Set(values)) })
                else { throw Failure.unsupported }
            }
        }
        guard let hijack = config["hijackWindowCycleHotkey"] as? Bool,
              let cycleEnabled = config["enableWindowCycleKey"] as? Bool,
              let cycleKey = config["windowCycleKey"] as? String,
              config["hijackCommandTab"] is Bool else { throw Failure.malformed }
        guard !hijack || !cycleEnabled || cycleKey == "grave" else { throw Failure.unsupported }
        let relevantNames = primaryNames + ["enableAssignHotkey", "assignKeyTriggerKeys", "enableHideOthersHotkey",
            "hideOnFocusTriggerKeys", "hijackCommandTab", "hijackWindowCycleHotkey", "enableWindowCycleKey", "windowCycleKey"]
        var relevant = Dictionary(uniqueKeysWithValues: relevantNames.compactMap { name in config[name].map { (name, $0) } })
        relevant["descriptions"] = descriptions
        let fingerprintData = try JSONSerialization.data(withJSONObject: relevant, options: [.sortedKeys])
        return .init(processIdentity: identity, observedAtUptime: now, isCompatible: true, statusReason: nil,
            appTrigger: triggers[0], blockedTriggers: triggers, appBundlesByKeyCode: bundles, tapIDs: tapIDs,
            capturesCommandGrave: hijack && cycleEnabled,
            configurationFingerprint: String(decoding: fingerprintData, as: UTF8.self))
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 262_144, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.malformed }
        return value
    }
}
