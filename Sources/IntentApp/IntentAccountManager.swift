import AppKit
import Combine
import Foundation
import IntentCore
import LocalAuthentication
import Security
import Supabase

enum IntentAccountPhase: Equatable {
    case loading
    case choosing
    case guest
    case signedIn(userID: String, email: String)
}

enum IntentAccountSyncState: Equatable {
    case localOnly
    case syncing
    case synced(Date)
    case offline(String)
}

@MainActor
final class IntentAccountManager: ObservableObject {
    private static let accountChoiceKey = "intentAccountChoiceMade"
    private static let cloudTable = "intent_user_state"
    private static let redirectURL = URL(string: "intent://auth-callback")!
    private static let passwordResetURL = URL(string: "intent://password-reset")!

    @Published private(set) var phase: IntentAccountPhase = .loading
    @Published private(set) var syncState: IntentAccountSyncState = .localOnly
    @Published private(set) var workspaceRevision = UUID()
    @Published var isPresentingAccount = false
    @Published private(set) var isResettingPassword = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    var onPortablePreferencesApplied: (() -> Void)?

    private weak var model: IntentAppModel?
    private let configuration: IntentSupabaseConfiguration?
    private let client: SupabaseClient?
    private var activeUserID: UUID?
    private var isApplyingWorkspace = false
    private var isRefreshingCloud = false
    private var hasStarted = false
    private var syncTask: Task<Void, Never>?
    private var authEventsTask: Task<Void, Never>?
    private var defaultsCancellable: AnyCancellable?
    private var lastPortablePreferences: IntentPortablePreferences?
    private var logicalWorkspaceUpdatedAt = Date()

    init() {
        configuration = IntentSupabaseConfiguration.load()
        if let configuration {
            client = SupabaseClient(
                supabaseURL: configuration.url,
                supabaseKey: configuration.publishableKey,
                options: SupabaseClientOptions(
                    auth: .init(
                        storage: IntentAuthSessionStorage(),
                        redirectToURL: Self.redirectURL,
                        storageKey: "intent-auth-session",
                        emitLocalSessionAsInitialSession: true
                    )
                )
            )
        } else {
            client = nil
        }

        defaultsCancellable = NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.portablePreferencesDidChange()
        }
    }

    deinit {
        defaultsCancellable?.cancel()
        syncTask?.cancel()
        authEventsTask?.cancel()
    }

    var isConfigured: Bool { client != nil }

    var accountEmail: String? {
        guard case .signedIn(_, let email) = phase else { return nil }
        return email
    }

    var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    var requiresFirstRunChoice: Bool {
        phase == .choosing
    }

    var configurationMessage: String? {
        guard client == nil else { return nil }
        return "Account sync is not configured in this build yet. Guest mode remains fully available."
    }

    var syncStatusText: String {
        switch syncState {
        case .localOnly:
            return "Saved on this Mac"
        case .syncing:
            return "Syncing..."
        case .synced(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
        case .offline:
            return "Saved locally - sync will retry"
        }
    }

    func attach(model: IntentAppModel) {
        self.model = model
        model.onWorkspaceChanged = { [weak self] in
            self?.workspaceDidChange()
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        lastPortablePreferences = capturePreferences()

        guard let client else {
            prepareGuestProfile()
            phase = UserDefaults.standard.bool(forKey: Self.accountChoiceKey) ? .guest : .choosing
            return
        }

        observeAuthEvents(client)
        do {
            let session = try await client.auth.session
            try await activateAccount(session: session)
        } catch {
            prepareGuestProfile()
            phase = UserDefaults.standard.bool(forKey: Self.accountChoiceKey) ? .guest : .choosing
            syncState = .localOnly
            if error is IntentAccountError {
                errorMessage = Self.humanReadable(error)
            }
        }
    }

    func presentAccount() {
        errorMessage = nil
        noticeMessage = nil
        isPresentingAccount = true
    }

    func dismissAccount() {
        guard !requiresFirstRunChoice else { return }
        errorMessage = nil
        noticeMessage = nil
        isResettingPassword = false
        isPresentingAccount = false
    }

    @discardableResult
    func handleAuthCallback(_ url: URL) -> Bool {
        guard let callbackKind = IntentAccountCallbackKind.classify(url),
              let client else {
            return false
        }

        Task {
            await performAccountAction {
                let session = try await client.auth.session(from: url)
                try await self.activateAccount(session: session)
                if callbackKind == .passwordReset {
                    self.isResettingPassword = true
                    self.isPresentingAccount = true
                    self.noticeMessage = "Choose a new password for your Intent account."
                } else {
                    self.isPresentingAccount = false
                    self.noticeMessage = "Your email is confirmed and your Intent workspace is ready."
                }
            }
        }
        return true
    }

    func continueAsGuest() {
        guard !isBusy else { return }
        errorMessage = nil
        noticeMessage = nil
        syncTask?.cancel()
        persistCurrentWorkspaceLocally()
        switchToGuestProfile()
        UserDefaults.standard.set(true, forKey: Self.accountChoiceKey)
        phase = .guest
        syncState = .localOnly
        isPresentingAccount = false
    }

    func signUp(email: String, password: String, confirmation: String) async {
        guard validate(email: email, password: password, confirmation: confirmation) else { return }
        guard let client else {
            errorMessage = configurationMessage
            return
        }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        await performAccountAction {
            let response = try await client.auth.signUp(email: normalizedEmail, password: password)
            if let session = response.session {
                try await self.activateAccount(session: session)
                self.isPresentingAccount = false
            } else {
                self.noticeMessage = "Check \(normalizedEmail) to confirm your account, then return here and sign in."
            }
        }
    }

    func signIn(email: String, password: String) async {
        guard validate(email: email, password: password, confirmation: nil) else { return }
        guard let client else {
            errorMessage = configurationMessage
            return
        }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        await performAccountAction {
            let session = try await client.auth.signIn(email: normalizedEmail, password: password)
            try await self.activateAccount(session: session)
            self.isPresentingAccount = false
        }
    }

    func signInWithGoogle() async {
        guard let client else {
            errorMessage = configurationMessage
            return
        }

        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        noticeMessage = nil
        do {
            let authorizationURL = try client.auth.getOAuthSignInURL(
                provider: .google,
                redirectTo: Self.redirectURL
            )
            guard NSWorkspace.shared.open(authorizationURL) else {
                throw IntentAccountError.couldNotOpenBrowser
            }
            noticeMessage = "Finish signing in with Google in your browser. Intent will reopen automatically."
        } catch {
            errorMessage = Self.humanReadable(error)
        }
        isBusy = false
    }

    func sendPasswordReset(email: String) async {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.contains("@") else {
            errorMessage = "Enter the email address for your Intent account."
            return
        }
        guard let client else {
            errorMessage = configurationMessage
            return
        }

        await performAccountAction {
            try await client.auth.resetPasswordForEmail(
                normalized,
                redirectTo: Self.passwordResetURL
            )
            self.noticeMessage = "Password reset instructions were sent to \(normalized)."
        }
    }

    func updatePassword(_ password: String, confirmation: String) async {
        guard password.count >= 8 else {
            errorMessage = "Use at least 8 characters for your password."
            return
        }
        guard password == confirmation else {
            errorMessage = "Those passwords do not match."
            return
        }
        guard let client else {
            errorMessage = configurationMessage
            return
        }

        await performAccountAction {
            _ = try await client.auth.update(user: UserAttributes(password: password))
            self.isResettingPassword = false
            self.isPresentingAccount = false
            self.noticeMessage = "Your password has been updated."
        }
    }

    func signOut() async {
        guard !isBusy else { return }
        guard let client else {
            continueAsGuest()
            return
        }
        guard model?.hasActiveSession != true else {
            errorMessage = "Finish the active intention before signing out."
            return
        }

        syncTask?.cancel()
        persistCurrentWorkspaceLocally()
        isBusy = true
        errorMessage = nil
        do {
            try await client.auth.signOut(scope: .local)
        } catch {
            errorMessage = "Intent signed out locally, but could not notify the server."
        }
        activeUserID = nil
        isResettingPassword = false
        switchToGuestProfile()
        phase = .guest
        syncState = .localOnly
        isBusy = false
        isPresentingAccount = false
    }

    func refreshCloudWorkspace() async {
        guard let client, let userID = activeUserID else { return }
        guard !isRefreshingCloud else { return }
        guard model?.hasActiveSession != true else {
            errorMessage = "Finish the active intention before refreshing synced data."
            return
        }

        isRefreshingCloud = true
        defer { isRefreshingCloud = false }
        syncState = .syncing
        do {
            try await reconcileWorkspace(client: client, userID: userID)
        } catch {
            syncState = .offline("Cloud refresh failed")
            errorMessage = "Your local workspace is safe. Intent could not refresh cloud changes right now."
        }
    }

    func appBecameActive() {
        guard isSignedIn else { return }
        Task { await refreshCloudWorkspace() }
    }

    func customBackgroundDidChange() {
        guard hasStarted, !isApplyingWorkspace else { return }
        markWorkspaceModified()
        persistCurrentWorkspaceLocally()
        scheduleCloudUpload()
    }

    private func validate(email: String, password: String, confirmation: String?) -> Bool {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.contains("@"), normalized.contains(".") else {
            errorMessage = "Enter a valid email address."
            return false
        }
        guard password.count >= 8 else {
            errorMessage = "Use at least 8 characters for your password."
            return false
        }
        if let confirmation, password != confirmation {
            errorMessage = "Those passwords do not match."
            return false
        }
        return true
    }

    private func performAccountAction(_ action: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        noticeMessage = nil
        do {
            try await action()
        } catch {
            errorMessage = Self.humanReadable(error)
        }
        isBusy = false
    }

    private func activateAccount(session: Session) async throws {
        guard model?.hasActiveSession != true else {
            throw IntentAccountError.activeSession
        }

        syncTask?.cancel()
        persistCurrentWorkspaceLocally()
        let userID = session.user.id
        let directory = profileDirectory(for: userID)
        let local = loadWorkspaceCache(from: directory)
        let email = session.user.email ?? "Intent account"

        let remote: CloudWorkspaceRow?
        do {
            remote = try await fetchRemoteWorkspace(client: requireClient(), userID: userID)
        } catch {
            guard IntentOfflineAccountPolicy.canActivate(cachedWorkspace: local),
                  let local else {
                throw IntentAccountError.firstDeviceRequiresCloud
            }
            try apply(workspace: local, to: directory)
            finishAccountActivation(userID: userID, email: email)
            syncState = .offline("Cloud workspace unavailable")
            return
        }

        let selected: IntentAccountWorkspace
        let needsUpload: Bool
        if let remote, let local {
            if local.updatedAt > remote.payload.updatedAt {
                selected = local
                needsUpload = true
            } else {
                selected = remote.payload
                needsUpload = false
            }
        } else if let remote {
            selected = remote.payload
            needsUpload = false
        } else if let local {
            selected = local
            needsUpload = true
        } else {
            selected = IntentAccountWorkspace()
            needsUpload = true
        }

        try apply(workspace: selected, to: directory)
        finishAccountActivation(userID: userID, email: email)

        guard needsUpload else {
            syncState = .synced(Date())
            return
        }

        do {
            try await upload(workspace: selected, client: requireClient(), userID: userID)
        } catch {
            syncState = .offline("Cloud upload pending")
        }
    }

    private func finishAccountActivation(userID: UUID, email: String) {
        activeUserID = userID
        UserDefaults.standard.set(true, forKey: Self.accountChoiceKey)
        phase = .signedIn(userID: userID.uuidString, email: email)
        workspaceRevision = UUID()
    }

    private func requireClient() throws -> SupabaseClient {
        guard let client else { throw IntentAccountError.notConfigured }
        return client
    }

    private func observeAuthEvents(_ client: SupabaseClient) {
        authEventsTask?.cancel()
        authEventsTask = Task { [weak self] in
            for await change in client.auth.authStateChanges {
                guard !Task.isCancelled else { return }
                if change.event == .signedOut {
                    await MainActor.run {
                        guard let self, self.isSignedIn else { return }
                        self.syncTask?.cancel()
                        self.activeUserID = nil
                        self.switchToGuestProfile()
                        self.phase = .guest
                        self.syncState = .localOnly
                    }
                }
            }
        }
    }

    private func workspaceDidChange() {
        guard !isApplyingWorkspace else { return }
        markWorkspaceModified()
        persistCurrentWorkspaceLocally()
        scheduleCloudUpload()
    }

    private func portablePreferencesDidChange() {
        guard hasStarted, !isApplyingWorkspace else { return }
        let preferences = capturePreferences()
        guard preferences != lastPortablePreferences else { return }
        lastPortablePreferences = preferences
        markWorkspaceModified()
        persistCurrentWorkspaceLocally()
        scheduleCloudUpload()
    }

    private func markWorkspaceModified() {
        logicalWorkspaceUpdatedAt = Date()
    }

    private func scheduleCloudUpload() {
        guard let userID = activeUserID, let client else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.activeUserID == userID else { return }
            let workspace = self.currentWorkspace()
            do {
                try await self.upload(workspace: workspace, client: client, userID: userID)
            } catch {
                await MainActor.run {
                    self.syncState = .offline("Cloud upload failed")
                }
            }
        }
    }

    private func prepareGuestProfile() {
        let directory = IntentProfilePaths.guestDirectory()
        logicalWorkspaceUpdatedAt = loadWorkspaceCache(from: directory)?.updatedAt ?? Date()
        IntentBackgroundStore.useProfileDirectory(directory)
        if model?.profileDirectory != directory {
            model?.switchProfile(to: directory)
        }
        persistCurrentWorkspaceLocally()
    }

    private func switchToGuestProfile() {
        let directory = IntentProfilePaths.guestDirectory()
        let fallback = capturePreferences()
        let workspace = loadWorkspace(from: directory, fallbackPreferences: fallback)
        do {
            try apply(workspace: workspace, to: directory)
        } catch {
            errorMessage = "Intent could not restore the guest workspace: \(error.localizedDescription)"
        }
        activeUserID = nil
        workspaceRevision = UUID()
    }

    private func persistCurrentWorkspaceLocally() {
        guard model != nil else { return }
        let workspace = currentWorkspace()
        do {
            try write(workspace: workspace, to: model?.profileDirectory ?? IntentProfilePaths.guestDirectory())
        } catch {
            errorMessage = "Intent could not save this profile locally."
        }
    }

    private func currentWorkspace() -> IntentAccountWorkspace {
        IntentAccountWorkspace(
            intentions: model?.intentions ?? [],
            schedules: model?.schedules ?? [],
            preferences: capturePreferences(),
            customBackgroundPNG: try? Data(contentsOf: IntentBackgroundStore.customImageURL),
            updatedAt: logicalWorkspaceUpdatedAt
        )
    }

    private func loadWorkspace(
        from directory: URL,
        fallbackPreferences: IntentPortablePreferences
    ) -> IntentAccountWorkspace {
        if let cached = loadWorkspaceCache(from: directory) {
            return cached
        }
        let intentions = (try? IntentionStore(fileURL: IntentProfilePaths.intentionsURL(in: directory)).load()) ?? []
        let schedules = (try? IntentScheduleStore(fileURL: IntentProfilePaths.schedulesURL(in: directory)).load()) ?? []
        let preferences = loadPreferences(from: directory) ?? fallbackPreferences
        let background = try? Data(contentsOf: IntentProfilePaths.customBackgroundURL(in: directory))
        return IntentAccountWorkspace(
            intentions: intentions,
            schedules: schedules,
            preferences: preferences,
            customBackgroundPNG: background
        )
    }

    private func loadWorkspaceCache(from directory: URL) -> IntentAccountWorkspace? {
        guard let data = try? Data(contentsOf: IntentProfilePaths.workspaceCacheURL(in: directory)) else {
            return nil
        }
        return try? JSONDecoder().decode(IntentAccountWorkspace.self, from: data)
    }

    private func loadPreferences(from directory: URL) -> IntentPortablePreferences? {
        guard let data = try? Data(contentsOf: IntentProfilePaths.portablePreferencesURL(in: directory)) else {
            return nil
        }
        return try? JSONDecoder().decode(IntentPortablePreferences.self, from: data)
    }

    private func write(workspace: IntentAccountWorkspace, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try IntentionStore(fileURL: IntentProfilePaths.intentionsURL(in: directory)).save(workspace.intentions)
        try IntentScheduleStore(fileURL: IntentProfilePaths.schedulesURL(in: directory)).save(workspace.schedules)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(workspace.preferences).write(
            to: IntentProfilePaths.portablePreferencesURL(in: directory),
            options: .atomic
        )
        try encoder.encode(workspace).write(
            to: IntentProfilePaths.workspaceCacheURL(in: directory),
            options: .atomic
        )

        let backgroundURL = IntentProfilePaths.customBackgroundURL(in: directory)
        if let background = workspace.customBackgroundPNG {
            try FileManager.default.createDirectory(
                at: backgroundURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try background.write(to: backgroundURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: backgroundURL.path) {
            try FileManager.default.removeItem(at: backgroundURL)
        }
    }

    private func apply(workspace: IntentAccountWorkspace, to directory: URL) throws {
        isApplyingWorkspace = true
        defer { isApplyingWorkspace = false }
        logicalWorkspaceUpdatedAt = workspace.updatedAt
        try write(workspace: workspace, to: directory)
        IntentBackgroundStore.useProfileDirectory(directory)
        apply(preferences: workspace.preferences)
        model?.switchProfile(to: directory)
        workspaceRevision = UUID()
    }

    private func capturePreferences() -> IntentPortablePreferences {
        let defaults = UserDefaults.standard
        return IntentPortablePreferences(
            appearance: defaults.string(forKey: "intentAppearance") ?? "dark",
            welcomeTitle: defaults.string(forKey: "intentWelcomeTitle") ?? "Welcome to my desktop",
            backgroundSelection: defaults.string(forKey: "intentBackgroundSelection") ?? "none",
            didCompleteOnboarding: defaults.bool(forKey: "intentDidCompleteOnboarding"),
            zeroDriftWarningSuppressed: defaults.bool(forKey: "intentZeroDriftWarningSuppressed"),
            purposeModeEnabled: defaults.bool(forKey: "intentPurposeModeEnabled"),
            requireManualFinishBeforeSwitching: defaults.object(
                forKey: "intentRequireManualFinishBeforeSwitching"
            ) as? Bool ?? true,
            overlayShortcutData: defaults.data(forKey: "intentOverlayShortcut"),
            finishShortcutData: defaults.data(forKey: "intentFinishShortcut")
        )
    }

    private func apply(preferences: IntentPortablePreferences) {
        let defaults = UserDefaults.standard
        defaults.set(preferences.appearance, forKey: "intentAppearance")
        defaults.set(preferences.welcomeTitle, forKey: "intentWelcomeTitle")
        defaults.set(preferences.backgroundSelection, forKey: "intentBackgroundSelection")
        defaults.set(preferences.didCompleteOnboarding, forKey: "intentDidCompleteOnboarding")
        defaults.set(preferences.zeroDriftWarningSuppressed, forKey: "intentZeroDriftWarningSuppressed")
        defaults.set(preferences.purposeModeEnabled, forKey: "intentPurposeModeEnabled")
        defaults.set(
            preferences.requireManualFinishBeforeSwitching,
            forKey: "intentRequireManualFinishBeforeSwitching"
        )
        setOptional(preferences.overlayShortcutData, forKey: "intentOverlayShortcut", defaults: defaults)
        setOptional(preferences.finishShortcutData, forKey: "intentFinishShortcut", defaults: defaults)
        model?.requireManualFinishBeforeSwitching = preferences.requireManualFinishBeforeSwitching
        lastPortablePreferences = preferences
        onPortablePreferencesApplied?()
    }

    private func setOptional(_ data: Data?, forKey key: String, defaults: UserDefaults) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func profileDirectory(for userID: UUID) -> URL {
        IntentProfilePaths.accountDirectory(userID: userID.uuidString.lowercased())
    }

    private func reconcileWorkspace(client: SupabaseClient, userID: UUID) async throws {
        let directory = profileDirectory(for: userID)
        let local = loadWorkspaceCache(from: directory)
        let remote = try await fetchRemoteWorkspace(client: client, userID: userID)
        guard activeUserID == userID else { return }

        switch IntentWorkspaceResolver.resolve(local: local, remote: remote?.payload) {
        case .uploadLocal:
            guard let local else { return }
            try await upload(workspace: local, client: client, userID: userID)
        case .useRemote:
            guard let remote = remote?.payload else { return }
            try apply(workspace: remote, to: directory)
            syncState = .synced(Date())
        case .unchanged:
            syncState = .synced(Date())
        case .createEmpty:
            let workspace = IntentAccountWorkspace()
            try apply(workspace: workspace, to: directory)
            try await upload(workspace: workspace, client: client, userID: userID)
        }
    }

    private func fetchRemoteWorkspace(
        client: SupabaseClient,
        userID: UUID
    ) async throws -> CloudWorkspaceRow? {
        let rows: [CloudWorkspaceRow] = try await client
            .from(Self.cloudTable)
            .select()
            .eq("user_id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    private func upload(
        workspace: IntentAccountWorkspace,
        client: SupabaseClient,
        userID: UUID
    ) async throws {
        guard activeUserID == userID else { return }
        syncState = .syncing
        let row = CloudWorkspaceRow(
            userID: userID,
            revision: Int64((workspace.updatedAt.timeIntervalSince1970 * 1_000).rounded()),
            payload: workspace,
            updatedAt: workspace.updatedAt
        )
        try await client
            .from(Self.cloudTable)
            .upsert(row, onConflict: "user_id")
            .execute()
        if activeUserID == userID {
            syncState = .synced(Date())
        }
    }

    private static func humanReadable(_ error: Error) -> String {
        if let accountError = error as? IntentAccountError {
            return accountError.localizedDescription
        }
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("invalid login") || lower.contains("invalid credentials") {
            return "That email or password is not correct."
        }
        if lower.contains("already registered") || lower.contains("already exists") {
            return "An account already exists for that email. Try signing in instead."
        }
        if lower.contains("network") || lower.contains("offline") || lower.contains("internet") {
            return "Intent could not reach the account service. Check your connection and try again."
        }
        if lower.contains("cancel") {
            return "Sign in was cancelled."
        }
        return raw.isEmpty ? "Intent could not complete that account action." : raw
    }
}

private struct CloudWorkspaceRow: Codable {
    let userID: UUID
    let revision: Int64
    let payload: IntentAccountWorkspace
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case revision
        case payload
        case updatedAt = "updated_at"
    }
}

private struct IntentSupabaseConfiguration {
    let url: URL
    let publishableKey: String

    static func load() -> IntentSupabaseConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let environmentURL = environment["INTENT_SUPABASE_URL"]
        let environmentKey = environment["INTENT_SUPABASE_PUBLISHABLE_KEY"]
        if let rawURL = environmentURL, let key = environmentKey {
            return validated(rawURL: rawURL, key: key)
        }

        guard let resourceURL = bundledConfigurationURL(),
              let data = try? Data(contentsOf: resourceURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any],
              let rawURL = dictionary["SUPABASE_URL"] as? String,
              let key = dictionary["SUPABASE_PUBLISHABLE_KEY"] as? String,
              let configuration = validated(rawURL: rawURL, key: key) else {
            return nil
        }
        return configuration
    }

    private static func bundledConfigurationURL() -> URL? {
        if let resources = Bundle.main.resourceURL,
           let resourceBundle = Bundle(
               url: resources.appendingPathComponent("Intent_IntentApp.bundle", isDirectory: true)
           ),
           let configuration = resourceBundle.url(
               forResource: "SupabaseConfig",
               withExtension: "plist"
           ) {
            return configuration
        }

        return Bundle.module.url(forResource: "SupabaseConfig", withExtension: "plist")
    }

    private static func validated(rawURL: String, key: String) -> IntentSupabaseConfiguration? {
        let normalizedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerURL = normalizedURL.lowercased()
        let lowerKey = normalizedKey.lowercased()
        let placeholderURLTokens = ["your_project", "your-project", "example.supabase.co", "placeholder"]
        let placeholderKeyTokens = ["your_publishable_key", "your-publishable-key", "placeholder", "paste"]

        guard !normalizedURL.isEmpty,
              !normalizedKey.isEmpty,
              placeholderURLTokens.allSatisfy({ !lowerURL.contains($0) }),
              placeholderKeyTokens.allSatisfy({ !lowerKey.contains($0) }),
              !lowerKey.hasPrefix("sb_secret_"),
              !lowerKey.contains("service_role"),
              let url = URL(string: normalizedURL),
              url.scheme == "https",
              url.host?.hasSuffix(".supabase.co") == true else {
            return nil
        }

        return .init(url: url, publishableKey: normalizedKey)
    }
}

private enum IntentAccountError: LocalizedError {
    case activeSession
    case couldNotOpenBrowser
    case firstDeviceRequiresCloud
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .activeSession:
            return "Finish the active intention before switching accounts."
        case .couldNotOpenBrowser:
            return "Intent could not open your browser for Google sign-in. Try again after opening a browser."
        case .firstDeviceRequiresCloud:
            return "Connect to the internet once to open this account safely on this Mac. Your guest workspace is unchanged."
        case .notConfigured:
            return "Account sync is not configured in this build yet."
        }
    }
}

private final class IntentAuthSessionStorage: AuthLocalStorage, @unchecked Sendable {
    private let service = "dev.loganmondi.intent.account"

    func store(key: String, value: Data) throws {
        let query = baseQuery(key: key)
        let updates: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus) }

        var attributes = query
        updates.forEach { attributes[$0.key] = $0.value }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed {
            return nil
        }
        guard status == errSecSuccess else { throw keychainError(status) }
        return result as? Data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"]
        )
    }
}
