import Foundation
import IntentCore
import Security

enum IntentOpenAIKeyStore {
    private static let service = "dev.loganmondi.intent.openai"
    private static let account = "api-key"

    static func load() -> String? {
        if let environmentKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentKey.isEmpty {
            return environmentKey
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAIIntentionError.missingAPIKey }
        delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OpenAIIntentionError.keychain(status)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum OpenAIIntentionError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case server(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAI API key to build intentions with AI."
        case .invalidResponse:
            return "OpenAI returned a response Intent could not read. Please try again."
        case .server(let message):
            return message
        case .keychain(let status):
            return "Could not save the API key in Keychain (\(status))."
        }
    }
}

struct OpenAIIntentionService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generate(
        description: String,
        installedApps: [AllowedApp],
        apiKey: String
    ) async throws -> AIIntentionPlan {
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw OpenAIIntentionError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(
            description: description,
            installedApps: installedApps
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIIntentionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIIntentionError.server(Self.serverMessage(from: data, status: httpResponse.statusCode))
        }

        let envelope = try JSONDecoder().decode(OpenAIResponseEnvelope.self, from: data)
        guard let jsonText = envelope.output
            .flatMap(\.content)
            .first(where: { $0.type == "output_text" })?
            .text,
              let jsonData = jsonText.data(using: .utf8) else {
            throw OpenAIIntentionError.invalidResponse
        }
        return try JSONDecoder().decode(AIIntentionPlan.self, from: jsonData)
    }

    private func requestBody(description: String, installedApps: [AllowedApp]) -> [String: Any] {
        [
            "model": "gpt-5.6",
            "store": false,
            "reasoning": ["effort": "low"],
            "input": [
                ["role": "system", "content": AIIntentionPrompt.system],
                ["role": "user", "content": AIIntentionPrompt.user(
                    description: description,
                    installedApps: installedApps
                )]
            ],
            "text": [
                "verbosity": "low",
                "format": [
                    "type": "json_schema",
                    "name": "intent_intention_plan",
                    "strict": true,
                    "schema": Self.schema
                ]
            ]
        ]
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "intentions": [
                "type": "array",
                "minItems": 2,
                "maxItems": 8,
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "purpose": ["type": "string"],
                        "appBundleIdentifiers": [
                            "type": "array",
                            "items": ["type": "string"]
                        ],
                        "websites": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "value": ["type": "string"],
                                    "browserBundleIdentifier": ["type": "string"]
                                ],
                                "required": ["value", "browserBundleIdentifier"],
                                "additionalProperties": false
                            ]
                        ],
                        "allowBrowserSearches": ["type": "boolean"]
                    ],
                    "required": [
                        "name",
                        "purpose",
                        "appBundleIdentifiers",
                        "websites",
                        "allowBrowserSearches"
                    ],
                    "additionalProperties": false
                ]
            ]
        ],
        "required": ["intentions"],
        "additionalProperties": false
    ]

    private static func serverMessage(from data: Data, status: Int) -> String {
        if let payload = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data),
           !payload.error.message.isEmpty {
            return payload.error.message
        }
        return "OpenAI could not build intentions (HTTP \(status))."
    }
}

private struct OpenAIResponseEnvelope: Decodable {
    let output: [OpenAIOutputItem]
}

private struct OpenAIOutputItem: Decodable {
    let content: [OpenAIContentItem]

    private enum CodingKeys: String, CodingKey {
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent([OpenAIContentItem].self, forKey: .content) ?? []
    }
}

private struct OpenAIContentItem: Decodable {
    let type: String
    let text: String?
}

private struct OpenAIErrorEnvelope: Decodable {
    let error: OpenAIErrorBody
}

private struct OpenAIErrorBody: Decodable {
    let message: String
}
