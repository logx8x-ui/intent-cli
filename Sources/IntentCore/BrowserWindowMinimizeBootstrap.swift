import Foundation

/// One browser-side effect, owned durably by native code before it is offered.
/// Never reuse an effect ID or infer completion from a later window observation.
public struct BrowserWindowMinimizeBootstrap: Codable, Equatable {
    public enum Phase: String, Codable { case prepared, issued, result }
    public enum Outcome: String, Codable { case notDispatched, settled, uncertain }
    public var effectID: String
    public var nativeWindowID: UInt32
    public var planRevision: Int
    public var expiresAtUnixMS: Double
    public var descriptor: BrowserWindowVisibilityWindow
    public var phase: Phase
    public var outcome: Outcome?

    public init(effectID: String = UUID().uuidString, nativeWindowID: UInt32, planRevision: Int,
                expiresAtUnixMS: Double, descriptor: BrowserWindowVisibilityWindow) {
        self.effectID = effectID; self.nativeWindowID = nativeWindowID; self.planRevision = planRevision
        self.expiresAtUnixMS = expiresAtUnixMS; self.descriptor = descriptor; phase = .prepared; outcome = nil
    }
    public var isValid: Bool {
        !effectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && effectID.utf8.count <= 256
            && nativeWindowID > 0 && planRevision >= 0 && planRevision <= 9_007_199_254_740_991
            && expiresAtUnixMS.isFinite && expiresAtUnixMS > 0 && descriptor.isValid
            && ["normal", "maximized"].contains(descriptor.state)
            && (phase == .result ? outcome != nil : outcome == nil)
    }
    public enum Disposition: Equatable { case pending, noEffect, nativeConfirmation }
    public var disposition: Disposition {
        guard phase == .result, let outcome else { return .pending }
        switch outcome {
        case .notDispatched: return .noEffect
        case .settled: return .nativeConfirmation
        case .uncertain: return .pending
        }
    }
}

public struct BrowserWindowVisibilityEnforcement: Codable, Equatable {
    public var intentionSessionID: String
    public var browserSessionID: String
    public var browserProcessIdentity: BrowserProcessIdentity
    public var revision: Int
    public var windowIDs: [Int]

    public init?(record: BrowserWindowVisibilityRecord) {
        guard let proof = record.browserProcessIdentity, proof.isValid else { return nil }
        intentionSessionID = record.plan.intentionSessionID; browserSessionID = record.browserSessionID
        browserProcessIdentity = proof
        revision = record.plan.revision; windowIDs = record.verifiedWindowIDs
    }
}

/// Shared by native recovery and the isolated state-machine specifications.
public enum BrowserWindowBootstrapRecovery {
    public static func disposition(record: BrowserWindowVisibilityRecord?, browser: String, profile: String,
                                   intention: String, process: BrowserProcessIdentity, effectID: String,
                                   nativeWindowID: UInt32, browserWindowID: Int) -> BrowserWindowMinimizeBootstrap.Disposition {
        guard let record, record.isValid, record.browserBundleIdentifier == browser,
              record.browserSessionID == profile, record.plan.intentionSessionID == intention,
              record.browserProcessIdentity == process else { return .pending }
        // The append-only record is the sole source of grants. A successful
        // exact-record read with no effect proves this journal entry was never
        // published (including a crash between journal save and publication).
        guard let effect = record.bootstrapEffects.first(where: { $0.effectID == effectID }) else { return .noEffect }
        guard effect.nativeWindowID == nativeWindowID, effect.descriptor.windowID == browserWindowID else { return .pending }
        return effect.disposition
    }

    /// The caller has already durably journaled ownership. A definitive fence
    /// or rejection can retire it; a thrown write may have committed, so retain.
    @discardableResult
    public static func publishAfterJournal(mayEnforce: () -> Bool, publish: () throws -> Bool,
                                           retireUnpublished: () -> Void) -> Bool {
        guard mayEnforce() else { retireUnpublished(); return false }
        do {
            let accepted = try publish()
            if !accepted { retireUnpublished() }
            return accepted
        } catch { return false }
    }
}
