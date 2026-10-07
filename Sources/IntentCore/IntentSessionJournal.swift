import Foundation

/// Local-only history and replay data. A record describes a run, never a claim
/// that the user completed their work.
public struct SessionWorkspace: Codable {
    public struct Window: Codable, Equatable {
        public var app: String
        public var title: String
        public var nativeID: UInt32?
        public var process: BrowserProcessIdentity?
        public init(app: String, title: String, nativeID: UInt32? = nil, process: BrowserProcessIdentity? = nil) {
            self.app = app; self.title = title; self.nativeID = nativeID; self.process = process
        }
    }
    public struct Tab: Codable, Equatable {
        public var browser: String
        public var url: String
        public var title: String
        public var profileID: String?
        public var sessionID: String?
        public var nativeID: Int?
        public var windowID: Int?
        public var cookieStoreID: String?
        public init(browser: String, url: String, title: String, profileID: String? = nil,
                    sessionID: String? = nil, nativeID: Int? = nil, windowID: Int? = nil, cookieStoreID: String? = nil) {
            self.browser = browser; self.url = url; self.title = title; self.profileID = profileID
            self.sessionID = sessionID; self.nativeID = nativeID; self.windowID = windowID; self.cookieStoreID = cookieStoreID
        }
    }
    public var selection: QuickSelection
    public var windows: [Window]
    public var tabs: [Tab]
    public init(selection: QuickSelection, windows: [Window], tabs: [Tab]) {
        self.selection = selection; self.windows = windows; self.tabs = tabs
    }
    public struct LiveWindow {
        public var id: UInt32
        public var app: String
        public var title: String
        public var process: BrowserProcessIdentity?
        public init(id: UInt32, app: String, title: String, process: BrowserProcessIdentity? = nil) {
            self.id = id; self.app = app; self.title = title; self.process = process
        }
    }
    /// A missing web tab is a plan, never a side effect of reviewing a preset.
    public struct PendingTab: Equatable {
        public var descriptor: Tab
        public var descriptorIndex: Int
        public var ownerSessionID: String
        public var anchorTabID: Int
        public var windowID: Int
        public init(descriptor: Tab, descriptorIndex: Int = 0, ownerSessionID: String, anchorTabID: Int, windowID: Int) {
            self.descriptor = descriptor; self.descriptorIndex = descriptorIndex; self.ownerSessionID = ownerSessionID
            self.anchorTabID = anchorTabID; self.windowID = windowID
        }
    }
    public struct Resolution {
        public var selection: QuickSelection
        public var missing: Int
        public var pendingTabs: [PendingTab]
        public var problems: [String]
        /// Refreshed identities plus unresolved descriptors, for editing this staged draft.
        public var replayWorkspace: SessionWorkspace
    }
    /// Compatible conservative API: callers without a restoration transaction
    /// still report pending effects as missing rather than silently dropping them.
    public func resolve(runningApps: Set<String>, windows liveWindows: [LiveWindow], snapshots: [BrowserTabSnapshot]) -> (selection: QuickSelection, missing: Int) {
        let result = restorationPlan(runningApps: runningApps, windows: liveWindows, profiles: snapshots)
        return (result.selection, result.missing + result.pendingTabs.count)
    }

    /// Raw per-profile snapshots are required for durable profile routing. The
    /// returned IDs use the same merged representation as the overview.
    public func restorationPlan(runningApps: Set<String>, windows liveWindows: [LiveWindow],
                                profiles: [BrowserTabSnapshot], accessMode: IntentionAccessMode? = nil,
                                allowLegacyProfileMigration: Bool = false) -> Resolution {
        var draft = selection; draft.clearTargets()
        draft.accessMode = accessMode ?? selection.accessMode
        let scoped = Set(selection.windowIDsByApp.keys).union(selection.tabs.map(\.browser))
            .union(windows.map(\.app)).union(tabs.map(\.browser))
        let wholeApps = selection.apps.subtracting(scoped)
        draft.apps = wholeApps.intersection(runningApps)
        var missing = wholeApps.subtracting(runningApps).count
            + max(0, selection.windowIDsByApp.values.reduce(0) { $0 + $1.count } - windows.count)
            + max(0, selection.tabs.count - tabs.count)
        var problems: [String] = []
        var pending: [PendingTab] = []
        var replayWindows = windows; var replayTabs = tabs
        var usedWindows: Set<UInt32> = []
        for (offset, window) in windows.enumerated() {
            let candidates = liveWindows.filter { $0.app == window.app && !usedWindows.contains($0.id) }
            let sameLifetime = candidates.filter { $0.id == window.nativeID && window.process?.isValid == true && $0.process == window.process }
            let titled = candidates.filter { $0.title == window.title }
            let match = sameLifetime.count == 1 ? sameLifetime.first : (titled.count == 1 ? titled.first : nil)
            if let match {
                usedWindows.insert(match.id); draft.windowIDsByApp[window.app, default: []].insert(match.id); draft.apps.insert(window.app)
                replayWindows[offset] = .init(app: window.app, title: match.title, nativeID: match.id, process: match.process)
            }
            else { missing += 1 }
        }
        struct Row {
            let profile: BrowserTabSnapshot
            let tab: BrowserTabItem
            let id: Int
            let windowID: Int
        }
        var usedTabs: Set<QuickSelectionTab> = []
        let grouped = Dictionary(grouping: profiles, by: \.browserBundleIdentifier)
        // Reserve only a unique, actually live exact identity. An earlier
        // missing duplicate must not borrow a later descriptor's surviving tab
        // and then restore that survivor into the wrong original window.
        var exactReservations: [Int: QuickSelectionTab] = [:]
        for (offset, saved) in tabs.enumerated() {
            guard let id = saved.nativeID, let session = saved.sessionID else { continue }
            let browserProfiles = grouped[saved.browser] ?? []
            let owners = browserProfiles.filter {
                $0.browserSessionID == session && (saved.profileID == nil || $0.browserProfileID == saved.profileID)
            }
            guard owners.count == 1, let owner = owners.first else { continue }
            let matches = (owner.allTabs ?? owner.tabs).filter {
                $0.id == id && QuickSelection.isSelectable($0)
                    && (saved.cookieStoreID == nil || $0.cookieStoreID == saved.cookieStoreID)
            }
            guard matches.count == 1 else { continue }
            exactReservations[offset] = .init(browser: saved.browser,
                id: browserProfiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: session, id: id) : id)
        }
        let reservedTabs = Set(exactReservations.values)
        for (offset, saved) in tabs.enumerated() {
            let browserProfiles = grouped[saved.browser] ?? []
            let nonce = BrowserProfileSnapshots.nonce(browserProfiles)
            let sameLegacyLifetime = nonce != nil && selection.browserSessionIDs[saved.browser] == nonce
            let owners: [BrowserTabSnapshot]
            if let profile = saved.profileID {
                owners = browserProfiles.filter { $0.browserProfileID == profile }
            } else if let session = saved.sessionID {
                owners = browserProfiles.filter { $0.browserSessionID == session }
            } else { owners = browserProfiles }
            let rows = owners.flatMap { profile -> [Row] in
                guard let session = profile.browserSessionID else { return [] }
                return (profile.allTabs ?? profile.tabs).filter { tab in
                    QuickSelection.isSelectable(tab) && (saved.cookieStoreID == nil || tab.cookieStoreID == saved.cookieStoreID)
                }.map { tab in
                    Row(profile: profile, tab: tab,
                        id: browserProfiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: session, id: tab.id) : tab.id,
                        windowID: browserProfiles.count > 1 ? BrowserProfileSnapshots.compositeID(session: session, id: tab.windowID) : tab.windowID)
                }
            }.filter { !usedTabs.contains(.init(browser: saved.browser, id: $0.id)) }
            let exact = rows.filter { row in
                if let id = saved.nativeID, let session = saved.sessionID {
                    return row.profile.browserSessionID == session && row.tab.id == id
                }
                return sameLegacyLifetime && selection.tabs.contains(.init(browser: saved.browser, id: row.id))
                    && !reservedTabs.contains(.init(browser: saved.browser, id: row.id))
                    && Self.sameReplayURL(row.tab.url, saved.url)
            }
            let sameURL = rows.filter {
                Self.sameReplayURL($0.tab.url, saved.url) && !reservedTabs.contains(.init(browser: saved.browser, id: $0.id))
            }
            let remainingEquivalent = tabs.enumerated().dropFirst(offset).filter { index, descriptor in
                exactReservations[index] == nil && descriptor.browser == saved.browser
                    && descriptor.profileID == saved.profileID && descriptor.cookieStoreID == saved.cookieStoreID
                    && Self.sameReplayURL(descriptor.url, saved.url)
            }.count
            // Exact live identities win even after redirects/title changes.
            // URL fallback consumes one candidate per saved descriptor, preserving
            // duplicate multiplicity without selecting extra same-URL tabs.
            let candidates = !exact.isEmpty ? exact : sameURL
            // Old presets promised browser + website, before profiles were
            // recorded. Migrate that contract only from one explicitly queried
            // owner; never substitute for a descriptor that already has identity.
            let legacyOwner = allowLegacyProfileMigration && saved.profileID == nil && saved.sessionID == nil && saved.nativeID == nil
                && browserProfiles.count == 1 && owners.count == 1
                && owners.first?.allTabs != nil && owners.first?.browserProfileID.flatMap(UUID.init(uuidString:)) != nil
                && owners.first?.profileDiscoveryRequestIDs?.isEmpty == false
                && owners.first.map { Date().timeIntervalSince($0.updatedAt) >= -0.25 && Date().timeIntervalSince($0.updatedAt) <= 3 } == true
            let ownerKnown = owners.count == 1 && (saved.profileID != nil
                || saved.sessionID != nil && saved.sessionID == owners.first?.browserSessionID || sameLegacyLifetime || legacyOwner)
            let scopeKnown = !exact.isEmpty || ownerKnown
            let ordered = candidates.sorted { ($0.windowID, $0.tab.index, $0.id) < ($1.windowID, $1.tab.index, $1.id) }
            if scopeKnown, let row = ordered.first,
               (saved.nativeID != nil && exact.count == 1 || ordered.count <= remainingEquivalent),
               draft.pinBrowserSession(saved.browser, sessionID: nonce) {
                draft.tabs.insert(.init(browser: saved.browser, id: row.id)); draft.apps.insert(saved.browser)
                replayTabs[offset] = .init(browser: saved.browser, url: row.tab.url, title: row.tab.title,
                    profileID: row.profile.browserProfileID, sessionID: row.profile.browserSessionID,
                    nativeID: row.tab.id, windowID: row.tab.windowID, cookieStoreID: row.tab.cookieStoreID)
                usedTabs.insert(.init(browser: saved.browser, id: row.id)); continue
            }
            // Blocking a closed/missing resource must never launch it. An absent
            // blocked tab has nothing to block; ambiguity still requires review.
            if draft.accessMode == .blacklist, candidates.isEmpty, ownerKnown,
               owners.first?.allTabs != nil { continue }
            let durableOwner = ownerKnown
            if candidates.isEmpty, draft.accessMode == .whitelist, durableOwner,
               let owner = owners.first, let session = owner.browserSessionID,
               WebsiteFinderPolicy.validatedURL(saved.url) != nil,
               saved.cookieStoreID == nil || ["firefox-default", "firefox-private"].contains(saved.cookieStoreID!),
               let anchor = Self.restorationAnchor(saved: saved, profile: owner) {
                pending.append(.init(descriptor: saved, descriptorIndex: offset, ownerSessionID: session, anchorTabID: anchor.id, windowID: anchor.windowID))
                continue
            }
            missing += 1
            let browserName = saved.browser == "org.mozilla.firefox" ? "Firefox" : "Chrome"
            let problem = owners.isEmpty
                ? "Open the saved \(browserName) profile with Browser Guard connected, then choose this saved intention again."
                : "Review \(saved.title.isEmpty ? saved.url : saved.title) in \(browserName); its original tab or profile cannot be identified safely."
            if !problems.contains(problem) { problems.append(problem) }
        }
        var replaySelection = draft
        replaySelection.apps.formUnion(replayTabs.map(\.browser)); replaySelection.apps.formUnion(replayWindows.map(\.app))
        return .init(selection: draft, missing: missing, pendingTabs: pending, problems: problems,
            replayWorkspace: .init(selection: replaySelection, windows: replayWindows, tabs: replayTabs))
    }

    /// Preserve unresolved/pending resources when another live selection changes.
    /// The previous capture identifies resources the user could actually uncheck;
    /// missing resources do not vanish merely because they have no live tab ID.
    public func reconcilingSelection(previous: SessionWorkspace, current: SessionWorkspace) -> SessionWorkspace {
        var result = current
        func sameTabIdentity(_ left: Tab, _ right: Tab) -> Bool {
            left.browser == right.browser && left.nativeID != nil && left.nativeID == right.nativeID
                && left.sessionID != nil && left.sessionID == right.sessionID && left.profileID == right.profileID
                && left.cookieStoreID == right.cookieStoreID
        }
        func sameWindowIdentity(_ left: Window, _ right: Window) -> Bool {
            left.app == right.app && left.nativeID != nil && left.nativeID == right.nativeID
                && left.process != nil && left.process == right.process
        }
        result.tabs.append(contentsOf: tabs.filter { saved in
            !(current.selection.wholeBrowserApps ?? []).contains(saved.browser)
                && !previous.tabs.contains(where: { sameTabIdentity(saved, $0) })
                && !current.tabs.contains(where: { sameTabIdentity(saved, $0) })
        })
        result.windows.append(contentsOf: windows.filter { saved in
            let explicitlyWholeApp = current.selection.apps.contains(saved.app) && current.selection.windowIDsByApp[saved.app] == nil
                && !QuickSelection.browsers.contains(saved.app)
            return !explicitlyWholeApp && !previous.windows.contains(where: { sameWindowIdentity(saved, $0) })
                && !current.windows.contains(where: { sameWindowIdentity(saved, $0) })
        })
        result.selection.apps.formUnion(result.tabs.map(\.browser)); result.selection.apps.formUnion(result.windows.map(\.app))
        return result
    }

    /// Explicit Run may start the browser app, without any website URL. Its
    /// newly connected profile must still be verified before tab restoration.
    public func browsersToLaunchOnRun(runningApps: Set<String>, installedApps: Set<String>,
                                     accessMode: IntentionAccessMode) -> Set<String> {
        guard accessMode == .whitelist else { return [] }
        return Set(tabs.map(\.browser)).intersection(QuickSelection.browsers)
            .intersection(installedApps).subtracting(runningApps)
    }

    public mutating func removeResources(for app: String) {
        selection.apps.remove(app); selection.tabs = selection.tabs.filter { $0.browser != app }
        selection.windowIDsByApp.removeValue(forKey: app)
        selection.wholeBrowserApps?.remove(app); selection.startupAppIDs?.remove(app)
        windows.removeAll { $0.app == app }; tabs.removeAll { $0.browser == app }
    }

    public static func sameReplayURL(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ value: String) -> String {
            guard var url = URLComponents(string: value), url.scheme != nil else { return value }
            url.scheme = url.scheme?.lowercased(); url.host = url.host?.lowercased()
            if url.scheme == "https" && url.port == 443 || url.scheme == "http" && url.port == 80 { url.port = nil }
            return url.string ?? value
        }
        return normalized(lhs) == normalized(rhs)
    }
    private static func restorationAnchor(saved: Tab, profile: BrowserTabSnapshot) -> BrowserTabItem? {
        let rows = (profile.allTabs ?? profile.tabs).filter { tab in
            QuickSelection.isSelectable(tab) && (saved.cookieStoreID == nil || tab.cookieStoreID == saved.cookieStoreID)
        }
        if saved.sessionID == profile.browserSessionID, let window = saved.windowID,
           let anchor = rows.first(where: { $0.windowID == window && $0.active }) ?? rows.first(where: { $0.windowID == window }) { return anchor }
        // A verified profile is enough to create a missing website, but multiple
        // windows after a restart have no durable native window identity.
        guard Set(rows.map(\.windowID)).count == 1 else { return nil }
        return rows.first(where: \.active) ?? rows.first
    }
}

public struct IntentSessionRecord: Codable, Identifiable {
    public var id: UUID
    public var intention: Intention
    public var workspace: SessionWorkspace?
    public var startedAt: Date
    public var endedAt: Date?
    public var completedTasks: Set<Int>
    public var remainingSeconds: TimeInterval?
    public var savedIntentionID: String?
    public init(id: UUID, intention: Intention, workspace: SessionWorkspace?, startedAt: Date = Date()) {
        self.id = id; self.intention = intention; self.workspace = workspace
        self.startedAt = startedAt; completedTasks = []
    }
}

public struct WorkPeriodSchedule: Codable, Identifiable {
    public var id = UUID()
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    public var startMinute = 9 * 60
    public var endMinute = 17 * 60
    public var enabled = true
    public init() {}
    public func occurrence(at now: Date, calendar: Calendar = .current) -> DateInterval? {
        guard enabled, (0..<1440).contains(startMinute), (0..<1440).contains(endMinute), startMinute != endMinute else { return nil }
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let start = calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: day),
                  let endDay = calendar.date(byAdding: .day, value: endMinute <= startMinute ? 1 : 0, to: day),
                  let end = calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60, second: 0, of: endDay),
                  now >= start, now < end else { continue }
            return DateInterval(start: start, end: end)
        }
        return nil
    }
}

public struct IntentSessionJournal: Codable {
    public var records: [IntentSessionRecord] = []
    public var recovery: IntentSessionRecord?
    public var slotOrder: [String] = []
    public var workspaces: [String: SessionWorkspace] = [:]
    public var workSchedules: [WorkPeriodSchedule] = []
    public init() {}
    public mutating func upsert(_ record: IntentSessionRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
    }
    public func records(on day: Date, calendar: Calendar = .current) -> [IntentSessionRecord] {
        records.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }.sorted { $0.startedAt > $1.startedAt }
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
