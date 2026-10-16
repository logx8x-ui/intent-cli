import Foundation

/// Fixed vocabulary only. Never record assignments, configuration text, app names,
/// URLs, window titles, CLI output or localized error descriptions.
public enum RcmdCompatibilityFailure: String, Codable, Sendable {
    case processStarted, processTerminated, processIdentityUnavailable, processIdentityChanged
    case tapInventoryUnavailable, tapMissing, tapDisabled, tapLocationUnsupported, tapIDsChanged
    case configurationChanged, unsupportedVersion, cliUnavailable
    case cliTimedOut, cliCommandFailed, cliLaunchFailed, cliOutputTooLarge
    case keyboardLayoutChanged, schemaMalformed, schemaUnsupported, schemaIdentityMismatch, ambiguousKeys
    case readVerificationExpired
}

/// A failed inventory read and a positive observation of a disabled/replaced tap
/// must remain distinguishable even though both currently stop enforcement.
public struct RcmdTapInventory: Equatable, Sendable {
    public let available: Bool
    public let ids: Set<UInt32>
    public let disabled: Set<UInt32>
    public let unsupported: Set<UInt32>
    public init(available: Bool, ids: Set<UInt32> = [], disabled: Set<UInt32> = [], unsupported: Set<UInt32> = []) {
        self.available = available; self.ids = ids; self.disabled = disabled; self.unsupported = unsupported
    }
    public var failure: RcmdCompatibilityFailure? {
        if !available { return .tapInventoryUnavailable }
        if ids.isEmpty { return .tapMissing }
        if !unsupported.isEmpty { return .tapLocationUnsupported }
        if !disabled.isEmpty { return .tapDisabled }
        return nil
    }
}

public struct RcmdCompatibilityDiagnostic: Codable, Equatable, Sendable {
    public let reason: RcmdCompatibilityFailure
    public var precedingReason: RcmdCompatibilityFailure?
    public let observedAtUptime: TimeInterval
    public var lastVerifiedAtUptime: TimeInterval?
    public var expectedPID: Int32?
    public var observedPID: Int32?
    public var expectedLaunch: TimeInterval?
    public var observedLaunch: TimeInterval?
    public var keyboardLayoutRevision: UInt64?
    public let inventoryAvailable: Bool?
    public var expectedTapCount: Int
    public let observedTapCount: Int?
    public var expectedTapIDs: [UInt32]
    public let observedTapIDs: [UInt32]
    public let disabledTapIDs: [UInt32]
    public let unsupportedTapIDs: [UInt32]

    public init(reason: RcmdCompatibilityFailure, now: TimeInterval,
                expectedTapIDs: Set<UInt32> = [], inventory: RcmdTapInventory? = nil) {
        self.reason = reason; observedAtUptime = now
        inventoryAvailable = inventory?.available
        expectedTapCount = expectedTapIDs.count; observedTapCount = inventory.map { $0.ids.count }
        self.expectedTapIDs = Array(expectedTapIDs.sorted().prefix(16))
        observedTapIDs = Array((inventory?.ids ?? []).sorted().prefix(16))
        disabledTapIDs = Array((inventory?.disabled ?? []).sorted().prefix(16))
        unsupportedTapIDs = Array((inventory?.unsupported ?? []).sorted().prefix(16))
    }
}
