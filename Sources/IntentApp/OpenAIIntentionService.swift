import Foundation
import IntentCore

enum IntentAIError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case rateLimited
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Intent AI is not configured in this build."
        case .invalidResponse:
            return "Intent AI returned a response the app could not read. Please try again."
        case .rateLimited:
            return "You have made several AI requests. Wait a minute, then try again."
        case .server(let message):
            return message
        }
    }
}

enum IntentAIInstallation {
    private static let defaultsKey = "intent.ai.installation-id"

    static var identifier: String {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey),
           UUID(uuidString: stored) != nil {
            return stored
        }
        let identifier = UUID().uuidString.lowercased()
        UserDefaults.standard.set(identifier, forKey: defaultsKey)
        return identifier
    }
}

struct IntentAIService {
    private static let productionEndpoint = "https://intent-ai.logx8x.workers.dev/v1/intention-plans"
    private let session: URLSession
    private let endpoint: URL?

    init(session: URLSession = .shared, endpoint: URL? = nil) {
        self.session = session
        if let endpoint {
            self.endpoint = endpoint
        } else if let override = ProcessInfo.processInfo.environment["INTENT_AI_ENDPOINT"],
                  !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.endpoint = URL(string: override)
        } else {
            self.endpoint = URL(string: Self.productionEndpoint)
        }
    }

    func generate(
        description: String,
        installedApps: [AllowedApp],
        currentIntention: Intention? = nil,
        mode: IntentAIGenerationMode = .single
    ) async throws -> AIIntentionPlan {
        guard let endpoint else { throw IntentAIError.invalidEndpoint }

        let body = try JSONEncoder().encode(IntentAIRequest(
            version: 1,
            installationId: IntentAIInstallation.identifier,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            description: description,
            mode: mode,
            currentIntention: currentIntention,
            installedApps: installedApps
        ))

        var lastError: Error = IntentAIError.invalidResponse
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 75
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(IntentAIInstallation.identifier, forHTTPHeaderField: "X-Intent-Installation-ID")
                request.httpBody = body

                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw IntentAIError.invalidResponse
                }
                if httpResponse.statusCode == 429 {
                    throw IntentAIError.rateLimited
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    let error = IntentAIError.server(Self.serverMessage(from: data, status: httpResponse.statusCode))
                    guard Self.isRetryable(httpResponse.statusCode), attempt < 2 else { throw error }
                    lastError = error
                    try await Task.sleep(for: .milliseconds(450 * (attempt + 1)))
                    continue
                }

                do {
                    return try JSONDecoder().decode(AIIntentionPlan.self, from: data)
                } catch {
                    lastError = IntentAIError.invalidResponse
                    guard attempt < 2 else { throw lastError }
                    try await Task.sleep(for: .milliseconds(450 * (attempt + 1)))
                }
            } catch let error as IntentAIError {
                if case .rateLimited = error { throw error }
                lastError = error
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .milliseconds(450 * (attempt + 1)))
            } catch {
                lastError = error
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .milliseconds(450 * (attempt + 1)))
            }
        }
        throw lastError
    }

    private static func isRetryable(_ status: Int) -> Bool {
        status == 408 || status == 409 || status == 425 || status >= 500
    }

    private static func serverMessage(from data: Data, status: Int) -> String {
        if let payload = try? JSONDecoder().decode(IntentAIErrorEnvelope.self, from: data),
           !payload.error.isEmpty {
            return payload.error
        }
        return "Intent AI could not build intentions (HTTP \(status))."
    }
}

enum IntentAIGenerationMode: String, Encodable {
    case single
    case onboarding
    case split
}

private struct IntentAIRequest: Encodable {
    let version: Int
    let installationId: String
    let appVersion: String
    let description: String
    let mode: IntentAIGenerationMode
    let currentIntention: Intention?
    let installedApps: [AllowedApp]
}

private struct IntentAIErrorEnvelope: Decodable {
    let error: String
}
