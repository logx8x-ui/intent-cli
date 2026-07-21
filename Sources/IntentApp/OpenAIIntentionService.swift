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
        installedApps: [AllowedApp]
    ) async throws -> AIIntentionPlan {
        guard let endpoint else { throw IntentAIError.invalidEndpoint }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(IntentAIInstallation.identifier, forHTTPHeaderField: "X-Intent-Installation-ID")
        request.httpBody = try JSONEncoder().encode(IntentAIRequest(
            version: 1,
            installationId: IntentAIInstallation.identifier,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            description: description,
            installedApps: installedApps
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IntentAIError.invalidResponse
        }
        if httpResponse.statusCode == 429 {
            throw IntentAIError.rateLimited
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw IntentAIError.server(Self.serverMessage(from: data, status: httpResponse.statusCode))
        }

        do {
            return try JSONDecoder().decode(AIIntentionPlan.self, from: data)
        } catch {
            throw IntentAIError.invalidResponse
        }
    }

    private static func serverMessage(from data: Data, status: Int) -> String {
        if let payload = try? JSONDecoder().decode(IntentAIErrorEnvelope.self, from: data),
           !payload.error.isEmpty {
            return payload.error
        }
        return "Intent AI could not build intentions (HTTP \(status))."
    }
}

private struct IntentAIRequest: Encodable {
    let version: Int
    let installationId: String
    let appVersion: String
    let description: String
    let installedApps: [AllowedApp]
}

private struct IntentAIErrorEnvelope: Decodable {
    let error: String
}
