import Foundation
import Combine
import IntentCore

/// The user confirms the browser profile on a unique verification page before
/// Intent binds its durable extension identity. Chrome does not expose an
/// independently verifiable directory identity; Firefox also checks its owner
/// process. Subsequent checks require fresh replies from the bound identity.
@MainActor
final class IntentBrowserSetupConnectionMonitor: ObservableObject {
    private static weak var active: IntentBrowserSetupConnectionMonitor?
    @Published private var verifiedAt: [String: Date] = [:]
    var connectedProfileIDs: Set<String> {
        Set(verifiedAt.filter { IntentProfileSetupConfirmation.isFreshReceipt($0.value, now: Date()) }.map(\.key))
    }
    @Published private(set) var checking = false
    private var verificationPages: [String: URL] = [:]
    private var challenges: [String: (nonce: String, createdAt: Date)] = [:]
    private var confirmedProfiles = Set<String>()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private struct Context: Equatable {
        let profiles: [IntentLocalBrowserProfile]
        let preferences: IntentBrowserOnboardingPreferences
        let requiredVersion: String
    }
    private var context: Context?
    private func invalidateCheck() {
        generation = UUID(); task?.cancel(); task = nil; checking = false
    }

    func prepareVerification(for profile: IntentLocalBrowserProfile, root: URL) throws -> URL {
        invalidateCheck(); context = nil
        let folder = root.appendingPathComponent("profile-verification", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let nonce = UUID().uuidString
        let page = folder.appendingPathComponent(nonce + ".html")
        let profileName = profile.name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        let callback = IntentBuildChannel.current.authScheme + "://browser-setup-confirm?nonce=" + nonce
        let html = """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Intent browser connection</title><style>:root{color-scheme:dark}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#090a0e;color:#f2f3f7;font:17px/1.6 -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:520px;padding:32px}h1{font:42px Georgia,serif}p{color:#babdc8}</style>
        <main><h1>intent</h1><h2>Connect \(profileName)</h2><p>Check your browser’s profile indicator. If this is \(profileName), choose Connect this profile.</p><p><a style="display:inline-block;padding:12px 20px;background:#e6e8ed;color:#17181c;border-radius:10px;text-decoration:none" href="\(callback)">Connect this profile</a></p><p>If this is another profile, return to Intent and open the check in the intended profile. You can close this tab after setup.</p></main></html>
        """
        try Data(html.utf8).write(to: page, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: page.path)
        if let previous = verificationPages.updateValue(page, forKey: profile.id) { try? FileManager.default.removeItem(at: previous) }
        challenges[profile.id] = (nonce, Date())
        confirmedProfiles.remove(profile.id)
        Self.active = self
        verifiedAt.removeValue(forKey: profile.id)
        return page
    }

    static func handleConfirmation(_ url: URL, now: Date = Date()) -> Bool {
        guard let owner = active, !IntentRuntime.shared.model.hasActiveSession,
              let challenge = owner.challenges.first(where: {
                  IntentProfileSetupConfirmation.accepts(url, scheme: IntentBuildChannel.current.authScheme,
                    nonce: $0.value.nonce, createdAt: $0.value.createdAt, now: now)
              }),
              !owner.confirmedProfiles.contains(challenge.key) else { return false }
        owner.confirmedProfiles.insert(challenge.key)
        return true
    }

    func refresh(profiles: [IntentLocalBrowserProfile], preferences: IntentBrowserOnboardingPreferences,
                 requiredVersion: String, firefoxOwner: @escaping (URL) -> Int32?, bind: @escaping (String, String) -> Void) {
        let nextContext = Context(profiles: profiles, preferences: preferences, requiredVersion: requiredVersion)
        if context != nextContext { invalidateCheck(); context = nextContext }
        guard !IntentRuntime.shared.model.hasActiveSession else {
            invalidateCheck(); verifiedAt = [:]; return
        }
        let eligible = profiles.filter { $0.guardStatus.isMatching }
        let eligibleIDs = Set(eligible.map(\.id))
        verifiedAt = verifiedAt.filter { eligibleIDs.contains($0.key) && IntentProfileSetupConfirmation.isFreshReceipt($0.value, now: Date()) }
        guard task == nil else { return }
        let currentGeneration = generation
        checking = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == currentGeneration { self.checking = false; self.task = nil } }
            let now = Date()
            struct Query { let owner: BrowserTabSnapshot; let command: BrowserTabCommand; let base: URL }
            var queries: [Query] = []
            for browser in Set(eligible.map { $0.browser.rawValue }).sorted() {
                let base = BrowserTabSnapshotStore.fileURL(for: browser)
                let browserProfiles = eligible.filter { $0.browser.rawValue == browser }
                let needsBinding = browserProfiles.contains { preferences.profileIdentities[$0.id] == nil }
                let boundIdentities = Set(browserProfiles.compactMap { preferences.profileIdentities[$0.id] })
                for owner in BrowserProfileSnapshots.sessions(base: base, now: now) {
                    guard owner.browserBundleIdentifier == browser, let session = owner.browserSessionID,
                          let profileID = owner.browserProfileID, UUID(uuidString: profileID) != nil,
                          needsBinding || boundIdentities.contains(profileID) else { continue }
                    let command = BrowserTabCommand(tabID: -1, windowID: -1, createdAt: now,
                                                    action: .snapshot, browserSessionID: session)
                    let path = BrowserSelectedTabPresenceCheck.commandFileURL(
                        base: BrowserTabCommandStore.fileURL(for: browser), session: session)
                    do {
                        try JSONEncoder().encode(command).write(to: path, options: .atomic)
                        queries.append(.init(owner: owner, command: command, base: base))
                    } catch { continue }
                }
            }
            var replies: [BrowserTabSnapshot] = []
            func ownsProfile(_ owner: BrowserTabSnapshot, _ profile: IntentLocalBrowserProfile, bindings: [String: String]) -> Bool {
                guard let identity = owner.browserProfileID,
                      !bindings.contains(where: { $0.key != profile.id && $0.value == identity }) else { return false }
                if profile.browser == .firefox {
                    guard let pid = firefoxOwner(profile.directory), pid > 0,
                          owner.browserProcessIdentity?.pid == pid else { return false }
                }
                return true
            }
            // Stay below the two-second refresh period so a silent owner never
            // skips the next liveness check for an already connected profile.
            for _ in 0..<30 {
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                replies = queries.compactMap { query in
                    guard let session = query.owner.browserSessionID,
                          let data = try? Data(contentsOf: BrowserProfileSnapshots.discoveryPartition(query.base, session: session)),
                          let reply = try? JSONDecoder().decode(BrowserTabSnapshot.self, from: data),
                          BrowserProfileSnapshots.isDiscoveryReply(reply, owner: query.owner,
                            requestID: query.command.id, requestedAt: now),
                          reply.supportsProfileSetup(version: requiredVersion),
                          BrowserProfileSnapshots.sessions(base: query.base).contains(where: {
                              $0.browserSessionID == session && $0.browserProfileID == reply.browserProfileID
                                  && $0.supportsProfileSetup(version: requiredVersion)
                          }) else { return nil }
                    return reply
                }
                guard self.context == nextContext, IntentBrowserOnboardingPreferences.load() == preferences else { return }
                // An already-bound profile can become ready as soon as its
                // own query replies. Unrelated silent profiles must not delay
                // publication until this receipt is nearly stale.
                var ready = self.verifiedAt.filter { IntentProfileSetupConfirmation.isFreshReceipt($0.value, now: Date()) }
                for profile in eligible {
                    guard let expected = preferences.profileIdentities[profile.id] else { continue }
                    let matches = replies.filter {
                        $0.browserBundleIdentifier == profile.browser.rawValue && $0.browserProfileID == expected
                            && ownsProfile($0, profile, bindings: preferences.profileIdentities)
                    }
                    if matches.count == 1, let checkedAt = matches.first?.updatedAt,
                       IntentProfileSetupConfirmation.isFreshReceipt(checkedAt, now: Date()) {
                        ready[profile.id] = checkedAt
                    }
                }
                self.verifiedAt = ready
                if replies.count == queries.count { break }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            guard !Task.isCancelled, self.generation == currentGeneration, self.context == nextContext,
                  IntentBrowserOnboardingPreferences.load() == preferences else { return }
            var connected: [String: Date] = [:]
            var bindings = preferences.profileIdentities
            for profile in eligible {
                let owners = replies.filter { $0.browserBundleIdentifier == profile.browser.rawValue }
                let expected = preferences.profileIdentities[profile.id]
                let matches = owners.filter { owner in
                    guard let identity = owner.browserProfileID, UUID(uuidString: identity) != nil,
                          ownsProfile(owner, profile, bindings: bindings) else { return false }
                    if let expected { return identity == expected }
                    // Do not bind an incomplete set: another profile could have
                    // the same verification tab (for example after moving it).
                    guard self.confirmedProfiles.contains(profile.id),
                          let challenge = self.challenges[profile.id],
                          IntentProfileSetupConfirmation.isFreshChallenge(challenge.createdAt, now: Date()),
                          owners.count == queries.filter({ $0.owner.browserBundleIdentifier == profile.browser.rawValue }).count,
                          let page = self.verificationPages[profile.id],
                          owner.allTabs?.contains(where: { $0.url == page.absoluteString }) == true else { return false }
                    return true
                }
                guard matches.count == 1, let identity = matches.first?.browserProfileID else { continue }
                guard let checkedAt = matches.first?.updatedAt,
                      IntentProfileSetupConfirmation.isFreshReceipt(checkedAt, now: Date()) else { continue }
                connected[profile.id] = checkedAt
                if expected == nil { bindings[profile.id] = identity; bind(profile.id, identity) }
            }
            self.verifiedAt = connected
        }
    }

    func cancel() {
        invalidateCheck(); context = nil; verifiedAt = [:]
        for page in verificationPages.values { try? FileManager.default.removeItem(at: page) }
        verificationPages = [:]
        challenges = [:]; confirmedProfiles = []
        if Self.active === self { Self.active = nil }
    }
}
