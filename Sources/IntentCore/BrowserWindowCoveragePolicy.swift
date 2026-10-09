import Foundation

/// Coverage is intentionally limited to positively observed AX standard windows
/// plus authoritative browser reports. AX-absent, unreported CG backing windows
/// are not classified as browser windows and are never claimed to be covered.
public enum BrowserWindowCoveragePolicy {
    /// Only explicit overview startup may choose a selected foreground tab.
    /// Never use a stale profile, an unselected tab, or disturb DBT's Run anchor.
    public static func startupTab(snapshot: BrowserTabSnapshot, expectedSession: String,
                                  selected: Set<Int>, preservesForeground: Bool) -> BrowserTabItem? {
        guard !preservesForeground, snapshot.browserSessionID == expectedSession else { return nil }
        let tabs = (snapshot.allTabs ?? snapshot.tabs).filter { selected.contains($0.id) && QuickSelection.isSelectable($0) }
            .sorted { ($0.windowID, $0.index, $0.id) < ($1.windowID, $1.index, $1.id) }
        return tabs.first(where: { $0.active && $0.windowFocused == true }) ?? tabs.first(where: \.active) ?? tabs.first
    }
    public struct NativeIdentity: Hashable {
        public var bundleIdentifier: String
        public var pid: Int32
        public var launched: Double
        public var windowID: UInt32
        public init(bundleIdentifier: String, pid: Int32, launched: Double, windowID: UInt32) {
            self.bundleIdentifier = bundleIdentifier; self.pid = pid; self.launched = launched; self.windowID = windowID
        }
        public var isValid: Bool { !bundleIdentifier.isEmpty && pid > 0 && launched.isFinite && windowID > 0 }
    }
    public struct NativeWindow: Equatable {
        public var identity: NativeIdentity
        public var title: String
        public var frame: CGRect
        public init(identity: NativeIdentity, title: String, frame: CGRect) {
            self.identity = identity; self.title = title; self.frame = frame
        }
    }
    public struct StandardWindow {
        public var bundleIdentifier: String
        public var processIdentity: BrowserProcessIdentity
        public var title: String
        public var frame: CGRect
        public init(bundleIdentifier: String, processIdentity: BrowserProcessIdentity, title: String, frame: CGRect) {
            self.bundleIdentifier = bundleIdentifier; self.processIdentity = processIdentity; self.title = title; self.frame = frame
        }
    }
    public struct Inventory {
        public var windows: [NativeWindow]
        public var observedStandard: Set<NativeIdentity>
        public init(windows: [NativeWindow], observedStandard: Set<NativeIdentity>) {
            self.windows = windows; self.observedStandard = observedStandard
        }
    }
    public struct ReportedIdentity: Hashable {
        public var bundleIdentifier: String
        public var browserSessionID: String
        public var windowID: Int
        public init(bundleIdentifier: String, browserSessionID: String, windowID: Int) {
            self.bundleIdentifier = bundleIdentifier; self.browserSessionID = browserSessionID; self.windowID = windowID
        }
    }
    public struct ReportedWindow {
        public var identity: ReportedIdentity
        public var processIdentity: BrowserProcessIdentity
        public var title: String
        public var frame: CGRect
        public init(identity: ReportedIdentity, processIdentity: BrowserProcessIdentity, title: String, frame: CGRect) {
            self.identity = identity; self.processIdentity = processIdentity; self.title = title; self.frame = frame
        }
    }
    public struct Coverage {
        public var browserBundleIdentifier: String
        public var matches: [ReportedIdentity: NativeIdentity]
        public var unreported: [NativeWindow]
        public var knownProfiles: Set<String>
        public var observableIdentities: Set<NativeIdentity>
        /// Only earned after a complete profile inventory bracketed by a live
        /// native observation; never inferred for windows born after the query.
        public var profileExclusions: [NativeIdentity: Set<String>]
        public var invalidatedMatches: Set<ReportedIdentity>
        public var anchorBackedMatches: Set<ReportedIdentity>
        public init(browserBundleIdentifier: String, matches: [ReportedIdentity: NativeIdentity], unreported: [NativeWindow],
                    knownProfiles: Set<String>, observableIdentities: Set<NativeIdentity>, profileExclusions: [NativeIdentity: Set<String>] = [:], invalidatedMatches: Set<ReportedIdentity> = [], anchorBackedMatches: Set<ReportedIdentity> = []) {
            self.browserBundleIdentifier = browserBundleIdentifier; self.matches = matches; self.unreported = unreported
            self.knownProfiles = knownProfiles; self.observableIdentities = observableIdentities
            self.profileExclusions = profileExclusions; self.invalidatedMatches = invalidatedMatches
            self.anchorBackedMatches = anchorBackedMatches
        }
        public func retainingContinuous(_ identities: Set<NativeIdentity>) -> Coverage {
            var result = self
            result.invalidatedMatches.formUnion(matches.filter { anchorBackedMatches.contains($0.key) && !identities.contains($0.value) }.keys)
            result.matches = matches.filter { identities.contains($0.value) }
            result.profileExclusions = profileExclusions.filter { identities.contains($0.key) }
            return result
        }
    }
    public enum Reason: String { case inventoryUnavailable, invalidReport, ambiguousIdentity, selectedWindowMissing, discoveryUnavailable, hidingUnconfirmed }
    public enum Result { case complete(Coverage), incomplete(Reason) }
    public struct Failure: Equatable {
        public var browserBundleIdentifier: String
        public var reason: Reason
        public var window: NativeIdentity?
        public var message: String {
            "The intention stopped because Intent could not confirm the visibility of another Chrome window. Its workspace is being released safely."
        }
        public init(browserBundleIdentifier: String, reason: Reason, window: NativeIdentity? = nil) {
            self.browserBundleIdentifier = browserBundleIdentifier; self.reason = reason; self.window = window
        }
    }
    public static func validFrame(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0 && frame.width <= 100_000 && frame.height <= 100_000
            && abs(frame.minX) <= 100_000 && abs(frame.minY) <= 100_000
    }
    public static func candidates(_ window: StandardWindow, native: [NativeWindow]) -> Set<NativeIdentity> {
        guard window.processIdentity.isValid, validFrame(window.frame), !window.title.isEmpty else { return [] }
        return Set(native.filter { item in
            item.identity.isValid && item.identity.bundleIdentifier == window.bundleIdentifier
                && item.identity.pid == window.processIdentity.pid && item.identity.launched == window.processIdentity.launched
                && BrowserWindowMatching.sameWindowTitle(item.title, window.title)
                && abs(item.frame.minX - window.frame.minX) <= 3 && abs(item.frame.minY - window.frame.minY) <= 3
                && abs(item.frame.width - window.frame.width) <= 3 && abs(item.frame.height - window.frame.height) <= 3
        }.map(\.identity))
    }
    /// Every AX standard window must bind uniquely, including the reverse map.
    /// Anchors are supplied only after the native boundary revalidates CFEqual
    /// against its own previously proven, process-scoped observation packet.
    public static func standardIdentities(native: [NativeWindow], standard: [StandardWindow]) -> Set<NativeIdentity>? {
        standardIdentityBindings(native: native, standard: standard).map(Set.init)
    }
    /// Shared identity-only anchor validation. Native callers provide CFEqual;
    /// fixtures supply opaque tokens, never fabricated AX window objects.
    public static func continuingAnchors<Token>(native: [NativeWindow], standard: [StandardWindow],
        previous: [NativeIdentity: Token], current: [Token], equal: (Token, Token) -> Bool) -> [Int: NativeIdentity]? {
        guard current.count == standard.count else { return nil }
        for index in current.indices where current[..<index].contains(where: { equal($0, current[index]) }) { return nil }
        var result: [Int: NativeIdentity] = [:]
        for (identity, token) in previous {
            guard native.contains(where: { $0.identity == identity }) else { continue }
            let equalRows = current.indices.filter { equal(token, current[$0]) }
            // Closed AX windows may leave a CG backing surface behind. It is
            // not reserved without a live equal AX row, nor does its old proof survive.
            if equalRows.isEmpty { continue }
            guard equalRows.count == 1, let index = equalRows.first, result[index] == nil,
                  candidates(standard[index], native: native).contains(identity) else { return nil }
            result[index] = identity
        }
        return result
    }
    public static func standardIdentityBindings(native: [NativeWindow], standard: [StandardWindow],
                                                anchors: [Int: NativeIdentity] = [:]) -> [NativeIdentity]? {
        guard Set(native.map(\.identity)).count == native.count,
              Set(anchors.values).count == anchors.count,
              anchors.allSatisfy({ standard.indices.contains($0.key) && candidates(standard[$0.key], native: native).contains($0.value) }) else { return nil }
        var result = anchors
        var remaining = Set(standard.indices).subtracting(anchors.keys)
        while !remaining.isEmpty {
            let reserved = Set(result.values)
            let choices = remaining.map { ($0, candidates(standard[$0], native: native).subtracting(reserved)) }
            guard !choices.contains(where: { $0.1.isEmpty }) else { return nil }
            let unique = choices.filter { $0.1.count == 1 }
            guard !unique.isEmpty, Set(unique.compactMap { $0.1.first }).count == unique.count else { return nil }
            for (index, identities) in unique { result[index] = identities.first!; remaining.remove(index) }
        }
        return standard.indices.compactMap { result[$0] }
    }
    public static func evaluate(browserBundleIdentifier: String, native: [NativeWindow]?, observedStandard: Set<NativeIdentity>,
                                reported: [ReportedWindow], requiredSelected: Set<ReportedIdentity> = [],
                                knownProfiles: Set<String>? = nil, priorCoverage: Coverage? = nil,
                                continuousIdentities: Set<NativeIdentity> = [], witnessedBeforeSnapshot: Set<NativeIdentity> = []) -> Result {
        guard let native, native.allSatisfy({ $0.identity.isValid && validFrame($0.frame) }),
              Set(native.map(\.identity)).count == native.count,
              observedStandard.isSubset(of: Set(native.map(\.identity))) else { return .incomplete(.inventoryUnavailable) }
        let profiles = knownProfiles ?? Set(reported.map { $0.identity.browserSessionID })
        guard profiles.allSatisfy({ !$0.isEmpty }), Set(reported.map(\.identity)).count == reported.count,
              reported.allSatisfy({ $0.identity.bundleIdentifier == browserBundleIdentifier && profiles.contains($0.identity.browserSessionID)
                  && $0.identity.windowID >= 0 && $0.processIdentity.isValid }) else { return .incomplete(.invalidReport) }
        let continuity = continuousIdentities.intersection(observedStandard)
        let previous = priorCoverage?.browserBundleIdentifier == browserBundleIdentifier ? priorCoverage?.retainingContinuous(continuity) : nil
        guard !reported.contains(where: { previous?.invalidatedMatches.contains($0.identity) == true }) else { return .incomplete(.ambiguousIdentity) }
        var matches: [ReportedIdentity: NativeIdentity] = [:]
        var choices: [ReportedIdentity: Set<NativeIdentity>] = [:]
        for report in reported {
            var candidates = self.candidates(.init(bundleIdentifier: report.identity.bundleIdentifier, processIdentity: report.processIdentity,
                title: report.title, frame: report.frame), native: native)
            candidates = candidates.filter { previous?.profileExclusions[$0]?.contains(report.identity.browserSessionID) != true }
            if let anchored = previous?.matches[report.identity] {
                guard candidates.contains(anchored) else { return .incomplete(.ambiguousIdentity) }
                matches[report.identity] = anchored
            } else {
                // A report can close after its full reply and be replaced by a
                // same-looking native window before our final scan. New report
                // bindings require the native lifetime to predate that query.
                choices[report.identity] = candidates.intersection(witnessedBeforeSnapshot).intersection(continuity)
            }
        }
        guard Set(matches.values).count == matches.count else { return .incomplete(.ambiguousIdentity) }
        while !choices.isEmpty {
            let reserved = Set(matches.values)
            choices = choices.mapValues { $0.subtracting(reserved) }
            guard !choices.values.contains(where: \.isEmpty) else { return .incomplete(.ambiguousIdentity) }
            let unique = choices.filter { $0.value.count == 1 }
            guard !unique.isEmpty, Set(unique.values.compactMap(\.first)).count == unique.count else { return .incomplete(.ambiguousIdentity) }
            for (identity, candidates) in unique { matches[identity] = candidates.first!; choices.removeValue(forKey: identity) }
        }
        guard requiredSelected.isSubset(of: Set(matches.keys)) else { return .incomplete(.selectedWindowMissing) }
        let reportedNative = Set(matches.values)
        let observed = observedStandard.filter { $0.bundleIdentifier == browserBundleIdentifier }
        let missing = observed.subtracting(reportedNative)
        var exclusions = previous?.profileExclusions ?? [:]
        for identity in witnessedBeforeSnapshot.intersection(continuity) {
            for profile in profiles where !matches.contains(where: { $0.key.browserSessionID == profile && $0.value == identity }) {
                exclusions[identity, default: []].insert(profile)
            }
        }
        return .complete(.init(browserBundleIdentifier: browserBundleIdentifier, matches: matches,
            unreported: native.filter { missing.contains($0.identity) }, knownProfiles: profiles,
            observableIdentities: observed.union(reportedNative), profileExclusions: exclusions,
            invalidatedMatches: previous?.invalidatedMatches ?? [],
            anchorBackedMatches: Set(matches.filter { observed.contains($0.value) }.keys)))
    }
    public static func needsDiscovery(native: Set<NativeIdentity>, reported: Set<ReportedIdentity>) -> Bool {
        !native.isEmpty || !reported.isEmpty
    }

    /// A legacy metadata match cannot overrule a still-bound identity, an
    /// invalidated binding, or profile exclusion backed by live AX continuity.
    public static func permitsReportedCandidate(_ identity: ReportedIdentity, candidate: NativeIdentity,
                                                coverage: Coverage) -> Bool {
        guard !coverage.invalidatedMatches.contains(identity),
              coverage.profileExclusions[candidate]?.contains(identity.browserSessionID) != true else { return false }
        return coverage.matches[identity].map { $0 == candidate } ?? false
    }
    public static func isPostReceiptObservation(receiptAt: TimeInterval, sampledAt: TimeInterval,
                                                now: TimeInterval, deadline: TimeInterval) -> Bool {
        [receiptAt, sampledAt, now, deadline].allSatisfy(\.isFinite)
            && sampledAt > receiptAt && now >= sampledAt && now < deadline
    }
    /// Call only with request-correlated snapshots from coverageSnapshots().
    public static func reportedWindows(snapshots: [BrowserTabSnapshot]) -> [ReportedWindow]? {
        var result: [ReportedWindow] = []
        for snapshot in snapshots {
            guard let profile = snapshot.browserSessionID, !profile.isEmpty,
                  let proof = snapshot.browserProcessIdentity, proof.isValid, let tabs = snapshot.allTabs,
                  Set(tabs.map(\.id)).count == tabs.count,
                  tabs.allSatisfy({ $0.id >= 0 && $0.index >= 0 }) else { return nil }
            for (id, rows) in Dictionary(grouping: tabs, by: \.windowID) {
                let active = rows.filter(\.active)
                guard id >= 0, rows.map(\.index).sorted() == Array(0..<rows.count), active.count == 1, let frame = active[0].windowFrame?.rect, validFrame(frame),
                      rows.allSatisfy({ $0.windowFrame?.rect == frame }) else { return nil }
                result.append(.init(identity: .init(bundleIdentifier: snapshot.browserBundleIdentifier, browserSessionID: profile, windowID: id),
                    processIdentity: proof, title: active[0].title, frame: frame))
            }
        }
        return result
    }
}

/// Frozen initial identities survive failed observations; a successful native
/// effect releases an Add As You Go target, while restrictive mode retains it.
public struct BrowserWindowCoverageCohort {
    public enum Outcome { case minimized, closed, unresolved }
    private var windows: [BrowserWindowCoveragePolicy.NativeIdentity: BrowserWindowCoveragePolicy.NativeWindow]
    private var pending: [BrowserWindowCoveragePolicy.NativeIdentity: TimeInterval] = [:]
    private var confirmed: Set<BrowserWindowCoveragePolicy.NativeIdentity> = []
    private let allowsLaterWindows: Bool
    public init(windows: [BrowserWindowCoveragePolicy.NativeWindow], allowsLaterWindows: Bool) {
        self.windows = windows.reduce(into: [:]) { $0[$1.identity] = $1 }; self.allowsLaterWindows = allowsLaterWindows
    }
    public var initialResolved: Bool { Set(windows.keys).isSubset(of: confirmed) }
    public var targets: [BrowserWindowCoveragePolicy.NativeWindow] {
        windows.values.filter { !allowsLaterWindows || !confirmed.contains($0.identity) }
    }
    public mutating func beginPendingObservation(now: TimeInterval) {
        guard now.isFinite else { return }
        for identity in windows.keys where !confirmed.contains(identity) && pending[identity] == nil { pending[identity] = now }
    }
    public func expiredFailure(now: TimeInterval) -> BrowserWindowCoveragePolicy.Failure? {
        guard now.isFinite, let identity = pending.first(where: { now - $0.value >= 3 })?.key else { return nil }
        return .init(browserBundleIdentifier: identity.bundleIdentifier, reason: .hidingUnconfirmed, window: identity)
    }
    public mutating func enroll(_ window: BrowserWindowCoveragePolicy.NativeWindow) {
        if !allowsLaterWindows && windows[window.identity] == nil { windows[window.identity] = window }
    }
    public mutating func release(_ identity: BrowserWindowCoveragePolicy.NativeIdentity) {
        windows.removeValue(forKey: identity); pending.removeValue(forKey: identity); confirmed.remove(identity)
    }
    public mutating func observe(_ identity: BrowserWindowCoveragePolicy.NativeIdentity, outcome: Outcome, now: TimeInterval) -> BrowserWindowCoveragePolicy.Failure? {
        guard windows[identity] != nil, now.isFinite else { return nil }
        switch outcome {
        case .closed: release(identity)
        case .minimized: pending.removeValue(forKey: identity); confirmed.insert(identity)
        case .unresolved:
            confirmed.remove(identity)
            let began = pending[identity] ?? now; pending[identity] = began
            if now - began >= 3 { return .init(browserBundleIdentifier: identity.bundleIdentifier, reason: .hidingUnconfirmed, window: identity) }
        }
        return nil
    }
}
