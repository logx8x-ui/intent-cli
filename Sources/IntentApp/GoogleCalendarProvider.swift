import AppKit
import CryptoKit
import Foundation
import IntentCore
import Network

struct GoogleCalendarConfiguration: Equatable {
    var clientID: String
    var clientSecret: String?

    private static let configResourceName = "GoogleCalendarConfig"

    static func load() -> GoogleCalendarConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let environmentSecret = normalizedSecret(environment["INTENT_GOOGLE_CLIENT_SECRET"])

        if let env = environment["INTENT_GOOGLE_CLIENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return .init(clientID: env, clientSecret: environmentSecret)
        }

        let moduleBundleName = "Intent_IntentApp.bundle"
        let resourceURLs = ["plist", "json"].flatMap { fileExtension in
            let fileName = "\(configResourceName).\(fileExtension)"
            return [
                Bundle.main.url(forResource: configResourceName, withExtension: fileExtension),
                Bundle.main.resourceURL?
                    .appendingPathComponent(moduleBundleName, isDirectory: true)
                    .appendingPathComponent(fileName),
                Bundle.main.bundleURL
                    .appendingPathComponent(moduleBundleName, isDirectory: true)
                    .appendingPathComponent(fileName),
                Bundle.main.bundleURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(moduleBundleName, isDirectory: true)
                    .appendingPathComponent(fileName)
            ].compactMap { $0 }
        }

        for url in resourceURLs {
            if url.pathExtension == "plist",
               let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let clientID = plist["CLIENT_ID"] as? String,
               !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !clientID.contains("YOUR_") {
                return .init(
                    clientID: clientID,
                    clientSecret: normalizedSecret(plist["CLIENT_SECRET"] as? String) ?? environmentSecret
                )
            }
            if url.pathExtension == "json",
               let data = try? Data(contentsOf: url),
               let object = try? JSONDecoder().decode(GoogleConfigFile.self, from: data),
               !object.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !object.clientID.contains("YOUR_") {
                return .init(
                    clientID: object.clientID,
                    clientSecret: normalizedSecret(object.clientSecret) ?? environmentSecret
                )
            }
        }
        return nil
    }

    private static func normalizedSecret(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("YOUR_") else {
            return nil
        }
        return value
    }
}

private struct GoogleConfigFile: Decodable {
    let clientID: String
    let clientSecret: String?
    let redirectURI: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case redirectURI = "redirect_uri"
        case CLIENT_ID
        case CLIENT_SECRET
        case REDIRECT_URI
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
            ?? container.decode(String.self, forKey: .CLIENT_ID)
        clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret)
            ?? container.decodeIfPresent(String.self, forKey: .CLIENT_SECRET)
        redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI)
            ?? container.decodeIfPresent(String.self, forKey: .REDIRECT_URI)
    }
}

@MainActor
final class GoogleCalendarProvider: CalendarProvider {
    let kind: CalendarProviderKind = .google
    private(set) var connectionState: CalendarConnectionState

    private let tokenVault: OAuthTokenVault
    private let session: URLSession
    private var preferences: CalendarPreferences
    private let onPreferencesChange: (CalendarPreferences) -> Void
    private let configuration: GoogleCalendarConfiguration?

    private let calendarScopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events"
    ]

    init(
        preferences: CalendarPreferences,
        onPreferencesChange: @escaping (CalendarPreferences) -> Void,
        tokenStore: SecureTokenStoring = KeychainTokenStore(),
        session: URLSession = .shared,
        configuration: GoogleCalendarConfiguration? = GoogleCalendarConfiguration.load()
    ) {
        self.preferences = preferences
        self.onPreferencesChange = onPreferencesChange
        self.tokenVault = OAuthTokenVault(store: tokenStore, account: "google-calendar")
        self.session = session
        self.configuration = configuration
        self.connectionState = CalendarConnectionState(provider: .google)

        if configuration == nil {
            connectionState.status = .configurationMissing
            connectionState.message = "Add a Google OAuth client ID to enable Google Calendar."
        } else if (try? tokenVault.load()) != nil {
            connectionState.status = .connected
            connectionState.message = nil
        }
    }

    func connect() async throws {
        guard let configuration else {
            connectionState.status = .configurationMissing
            connectionState.message = CalendarProviderError.configurationMissing.errorDescription
            throw CalendarProviderError.configurationMissing
        }

        connectionState.status = .connecting
        connectionState.message = nil

        do {
            let receiver = try OAuthLoopbackReceiver()
            let redirectURL = try await receiver.start()
            defer { receiver.cancel() }

            let verifier = Self.makeCodeVerifier()
            let challenge = Self.makeCodeChallenge(verifier)
            let state = UUID().uuidString

            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                .init(name: "client_id", value: configuration.clientID),
                .init(name: "redirect_uri", value: redirectURL.absoluteString),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: calendarScopes.joined(separator: " ")),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state)
            ]

            guard let authURL = components.url, NSWorkspace.shared.open(authURL) else {
                throw CalendarProviderError.underlying("Could not open Google sign-in.")
            }

            let callbackURL = try await receiver.waitForCallback()
            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let returnedError = items.first(where: { $0.name == "error" })?.value {
                throw CalendarProviderError.underlying(
                    returnedError == "access_denied"
                        ? "Google Calendar permission was not granted."
                        : "Google sign-in could not finish."
                )
            }
            let returnedState = items.first(where: { $0.name == "state" })?.value
            guard returnedState == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                throw CalendarProviderError.underlying("Google sign-in returned an invalid response.")
            }

            let tokens = try await exchangeCode(
                code,
                verifier: verifier,
                redirectURI: redirectURL.absoluteString,
                configuration: configuration
            )
            try tokenVault.save(tokens)
            connectionState.status = .connected
            connectionState.message = nil
            try await refreshCalendars()
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            connectionState.status = .error
            connectionState.message = error.localizedDescription
            throw error
        }
    }

    func disconnect() async {
        if let tokens = try? tokenVault.load() {
            await revoke(token: tokens.refreshToken ?? tokens.accessToken)
        }
        try? tokenVault.clear()
        preferences.googleVisibleCalendarIDs = []
        preferences.googleWriteCalendarID = nil
        preferences.googleTasksEnabled = false
        onPreferencesChange(preferences)
        connectionState = CalendarConnectionState(
            provider: .google,
            status: configuration == nil ? .configurationMissing : .disconnected,
            message: configuration == nil
                ? CalendarProviderError.configurationMissing.errorDescription
                : "Google Calendar disconnected. Local Intent schedules were kept."
        )
    }

    func refreshCalendars() async throws {
        guard configuration != nil else {
            connectionState.status = .configurationMissing
            return
        }
        let accessToken = try await validAccessToken()
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CalendarProviderError.offline
        }
        let payload = try JSONDecoder().decode(GoogleCalendarList.self, from: data)
        let calendars = payload.items.map {
            ExternalCalendar(
                id: $0.id,
                provider: .google,
                title: $0.summary,
                accountLabel: $0.id,
                allowsModifications: $0.accessRole == "owner" || $0.accessRole == "writer"
            )
        }
        connectionState.calendars = calendars
        connectionState.status = .connected
        connectionState.accountLabel = calendars.first(where: { $0.id.contains("@") })?.id

        if preferences.googleVisibleCalendarIDs.isEmpty {
            preferences.googleVisibleCalendarIDs = calendars.map(\.id)
        }
        if preferences.googleWriteCalendarID == nil {
            preferences.googleWriteCalendarID = calendars.first(where: { $0.id == "primary" })?.id
                ?? calendars.first(where: \.allowsModifications)?.id
        }
        connectionState.visibleCalendarIDs = Set(preferences.googleVisibleCalendarIDs)
        connectionState.writeCalendarID = preferences.googleWriteCalendarID
        onPreferencesChange(preferences)
    }

    func setVisibleCalendarIDs(_ ids: Set<String>) async {
        preferences.googleVisibleCalendarIDs = Array(ids).sorted()
        connectionState.visibleCalendarIDs = ids
        onPreferencesChange(preferences)
    }

    func setWriteCalendarID(_ id: String?) async {
        preferences.googleWriteCalendarID = id
        connectionState.writeCalendarID = id
        onPreferencesChange(preferences)
    }

    func fetchEvents(from start: Date, to end: Date) async throws -> [ExternalCalendarEvent] {
        guard connectionState.isConnected || (try? tokenVault.load()) != nil else { return [] }
        let accessToken = try await validAccessToken()
        var events: [ExternalCalendarEvent] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for calendarID in connectionState.visibleCalendarIDs {
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID)/events")!
            components.queryItems = [
                .init(name: "timeMin", value: formatter.string(from: start)),
                .init(name: "timeMax", value: formatter.string(from: end)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "100")
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                continue
            }
            let payload = try JSONDecoder().decode(GoogleEventList.self, from: data)
            events.append(contentsOf: payload.items.compactMap { item in
                guard let startAt = item.start.dateValue else { return nil }
                let linked = item.extendedProperties?.private?["intentScheduleId"]
                    ?? CalendarSyncMapper.scheduleID(from: item.description)
                let unsupported = item.recurrence?.contains(where: { $0.contains("FREQ=MONTHLY") || $0.contains("FREQ=YEARLY") }) == true
                return ExternalCalendarEvent(
                    id: item.id,
                    provider: .google,
                    calendarID: calendarID,
                    title: item.summary ?? "Event",
                    startAt: startAt,
                    endAt: item.end.dateValue,
                    isAllDay: item.start.date != nil,
                    linkedScheduleID: linked,
                    recurrenceSummary: item.recurrence?.isEmpty == false ? "Repeats" : nil,
                    supportsIntentSync: linked != nil && !unsupported,
                    kind: .event,
                    lastModifiedAt: item.updated.flatMap(formatter.date(from:))
                )
            })
        }

        if preferences.googleTasksEnabled {
            events.append(contentsOf: (try? await fetchTasks(accessToken: accessToken, from: start, to: end)) ?? [])
        }

        return CalendarSyncMapper.deduplicatedEvents(events)
    }

    func upsertLinkedEvent(
        for schedule: IntentSchedule,
        intentionName: String
    ) async throws -> ScheduleSyncMetadata {
        let accessToken = try await validAccessToken()
        guard let calendarID = connectionState.writeCalendarID ?? preferences.googleWriteCalendarID else {
            throw CalendarProviderError.notConnected
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let body = GoogleEventWrite(
            summary: CalendarSyncMapper.eventTitle(for: intentionName),
            description: CalendarSyncMapper.intentURL(for: schedule.id).absoluteString,
            start: .init(dateTime: formatter.string(from: schedule.scheduledAt)),
            end: .init(dateTime: formatter.string(from: schedule.scheduledAt.addingTimeInterval(3_600))),
            extendedProperties: .init(private: CalendarSyncMapper.googlePrivateProperty(scheduleID: schedule.id)),
            recurrence: Self.googleRecurrence(for: schedule)
        )
        let encoded = try JSONEncoder().encode(body)
        let rawEventID = schedule.sync?.externalEventID
        let eventID = (rawEventID?.isEmpty == false) ? rawEventID : nil
        let path: String
        let method: String
        if let eventID {
            path = "https://www.googleapis.com/calendar/v3/calendars/\(calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID)/events/\(eventID)"
            method = "PATCH"
        } else {
            path = "https://www.googleapis.com/calendar/v3/calendars/\(calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID)/events"
            method = "POST"
        }
        var request = URLRequest(url: URL(string: path)!)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CalendarProviderError.underlying("Could not sync the Google Calendar event.")
        }
        let saved = try JSONDecoder().decode(GoogleEvent.self, from: data)
        return ScheduleSyncMetadata(
            provider: .google,
            accountID: connectionState.accountLabel,
            calendarID: calendarID,
            externalEventID: saved.id,
            lastSyncedAt: Date(),
            lastLocalModifiedAt: Date(),
            lastExternalModifiedAt: saved.updated.flatMap(formatter.date(from:))
        )
    }

    func deleteLinkedEvent(metadata: ScheduleSyncMetadata) async throws {
        let accessToken = try await validAccessToken()
        let path = "https://www.googleapis.com/calendar/v3/calendars/\(metadata.calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? metadata.calendarID)/events/\(metadata.externalEventID)"
        var request = URLRequest(url: URL(string: path)!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode),
           http.statusCode != 404,
           http.statusCode != 410 {
            throw CalendarProviderError.underlying("Could not remove the Google Calendar event.")
        }
    }

    private func fetchTasks(accessToken: String, from start: Date, to end: Date) async throws -> [ExternalCalendarEvent] {
        var components = URLComponents(string: "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks")!
        components.queryItems = [
            .init(name: "showCompleted", value: "false"),
            .init(name: "maxResults", value: "50")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let payload = try JSONDecoder().decode(GoogleTaskList.self, from: data)
        return payload.items.compactMap { task in
            guard let dueString = task.due,
                  let due = ISO8601DateFormatter().date(from: dueString),
                  due >= start, due <= end else {
                return nil
            }
            return ExternalCalendarEvent(
                id: task.id,
                provider: .google,
                calendarID: "@default",
                title: task.title ?? "Task",
                startAt: due,
                supportsIntentSync: false,
                kind: .task
            )
        }
    }

    private func validAccessToken() async throws -> String {
        guard var tokens = try tokenVault.load() else {
            connectionState.status = .disconnected
            throw CalendarProviderError.notConnected
        }
        if tokens.isExpired {
            tokens = try await refresh(tokens)
            try tokenVault.save(tokens)
        }
        return tokens.accessToken
    }

    private func exchangeCode(
        _ code: String,
        verifier: String,
        redirectURI: String,
        configuration: GoogleCalendarConfiguration
    ) async throws -> OAuthTokenSet {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = [
            "code": code,
            "client_id": configuration.clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ]
        if let clientSecret = configuration.clientSecret {
            body["client_secret"] = clientSecret
        }
        request.httpBody = Self.formEncoded(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(GoogleOAuthErrorResponse.self, from: data))
                .flatMap { $0.errorDescription ?? $0.error }
            throw CalendarProviderError.underlying(
                detail.map { "Google sign-in could not finish: \($0)" }
                    ?? "Google token exchange failed."
            )
        }
        let payload = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        return OAuthTokenSet(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn)),
            tokenType: payload.tokenType,
            scope: payload.scope
        )
    }

    private func refresh(_ tokens: OAuthTokenSet) async throws -> OAuthTokenSet {
        guard let configuration, let refreshToken = tokens.refreshToken else {
            throw CalendarProviderError.notConnected
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = [
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if let clientSecret = configuration.clientSecret {
            body["client_secret"] = clientSecret
        }
        request.httpBody = Self.formEncoded(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            connectionState.status = .offline
            connectionState.message = "Google sign-in expired. Connect again."
            throw CalendarProviderError.offline
        }
        let payload = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        return OAuthTokenSet(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn)),
            tokenType: payload.tokenType,
            scope: payload.scope ?? tokens.scope
        )
    }

    private func revoke(token: String) async {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(["token": token])
        _ = try? await session.data(for: request)
    }

    private static func googleRecurrence(for schedule: IntentSchedule) -> [String]? {
        switch schedule.recurrence {
        case .once:
            return nil
        case .daily:
            return ["RRULE:FREQ=DAILY"]
        case .weekly:
            let map = [1: "SU", 2: "MO", 3: "TU", 4: "WE", 5: "TH", 6: "FR", 7: "SA"]
            let days = schedule.weekdays.compactMap { map[$0] }.joined(separator: ",")
            return ["RRULE:FREQ=WEEKLY;BYDAY=\(days.isEmpty ? "MO" : days)"]
        }
    }

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func makeCodeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func formEncoded(_ values: [String: String]) -> Data? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return values
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }
}

@MainActor
private final class OAuthLoopbackReceiver: @unchecked Sendable {
    private static let authorizationTimeout: Duration = .seconds(30 * 60)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.intent.google-oauth-loopback")
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: Result<URL, Error>?
    private var redirectURL: URL?
    private var timeoutTask: Task<Void, Never>?

    init() throws {
        let parameters = NWParameters.tcp
        guard let port = NWEndpoint.Port(rawValue: 0) else {
            throw CalendarProviderError.underlying("Could not reserve a Google sign-in callback.")
        }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            let receiver = self
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    receiver.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { connection in
                Task { @MainActor in
                    receiver.handle(connection)
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URL {
        if let pendingCallback {
            self.pendingCallback = nil
            return try pendingCallback.get()
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.authorizationTimeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.completeCallback(.failure(
                    CalendarProviderError.underlying("Google sign-in timed out. Please try again.")
                ))
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
        }
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener.cancel()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth2callback") else {
                completeStart(.failure(
                    CalendarProviderError.underlying("Could not start Google sign-in.")
                ))
                return
            }
            redirectURL = url
            completeStart(.success(url))
        case .failed(let error):
            let wrapped = CalendarProviderError.underlying(
                "Could not receive Google sign-in: \(error.localizedDescription)"
            )
            completeStart(.failure(wrapped))
            completeCallback(.failure(wrapped))
        case .cancelled:
            break
        default:
            break
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        let receiver = self
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 32_768
        ) { data, _, _, error in
            Task { @MainActor in
                if let error {
                    receiver.completeCallback(.failure(
                        CalendarProviderError.underlying(
                            "Google sign-in callback failed: \(error.localizedDescription)"
                        )
                    ))
                    connection.cancel()
                    return
                }
                receiver.handleRequest(data, connection: connection)
            }
        }
    }

    private func handleRequest(_ data: Data?, connection: NWConnection) {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            send(status: "400 Bad Request", body: "Invalid request.", on: connection)
            return
        }
        let pieces = requestLine.split(separator: " ")
        guard pieces.count >= 2,
              pieces[0] == "GET",
              let redirectURL,
              let callback = URL(string: "\(redirectURL.scheme ?? "http")://\(redirectURL.host ?? "127.0.0.1"):\(redirectURL.port ?? 80)\(pieces[1])"),
              callback.path == redirectURL.path else {
            send(status: "404 Not Found", body: "Not found.", on: connection)
            return
        }

        send(
            status: "200 OK",
            body: """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>Intent connected</title></head>
            <body style="font-family:-apple-system;margin:64px;color:#1d1d1f">
            <h2>Google Calendar is connected.</h2>
            <p>You can close this tab and return to Intent.</p>
            </body></html>
            """,
            contentType: "text/html; charset=utf-8",
            on: connection
        ) { [weak self] in
            self?.completeCallback(.success(callback))
        }
    }

    private func send(
        status: String,
        body: String,
        contentType: String = "text/plain; charset=utf-8",
        on connection: NWConnection,
        completion: (() -> Void)? = nil
    ) {
        let bodyData = Data(body.utf8)
        let headers = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r
        """
        var response = Data(headers.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            Task { @MainActor in
                connection.cancel()
                completion?()
            }
        })
    }

    private func completeStart(_ result: Result<URL, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(with: result)
    }

    private func completeCallback(_ result: Result<URL, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        } else {
            pendingCallback = result
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct GoogleTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

private struct GoogleOAuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct GoogleCalendarList: Decodable {
    struct Item: Decodable {
        let id: String
        let summary: String
        let accessRole: String?
    }

    let items: [Item]
}

private struct GoogleEventList: Decodable {
    let items: [GoogleEvent]
}

private struct GoogleEvent: Decodable {
    let id: String
    let summary: String?
    let description: String?
    let start: GoogleEventDate
    let end: GoogleEventDate
    let updated: String?
    let recurrence: [String]?
    let extendedProperties: GoogleExtendedProperties?
}

private struct GoogleEventDate: Codable {
    var date: String?
    var dateTime: String?

    var dateValue: Date? {
        if let dateTime {
            return ISO8601DateFormatter().date(from: dateTime)
        }
        if let date {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: date)
        }
        return nil
    }
}

private struct GoogleExtendedProperties: Codable {
    var `private`: [String: String]?
}

private struct GoogleEventWrite: Encodable {
    let summary: String
    let description: String
    let start: GoogleEventDate
    let end: GoogleEventDate
    let extendedProperties: GoogleExtendedProperties
    let recurrence: [String]?
}

private struct GoogleTaskList: Decodable {
    struct Item: Decodable {
        let id: String
        let title: String?
        let due: String?
    }

    let items: [Item]
}
