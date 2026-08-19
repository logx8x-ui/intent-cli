import Foundation

public struct PurposeIntentionMatch: Equatable {
    public let intentionID: String
    public let score: Double

    public init(intentionID: String, score: Double) {
        self.intentionID = intentionID
        self.score = score
    }
}

public enum PurposeIntentionMatcher {
    public static func bestMatch(
        for rawPurpose: String,
        in intentions: [Intention],
        minimumScore: Double = 0.84
    ) -> PurposeIntentionMatch? {
        let purpose = normalizedPhrase(rawPurpose)
        let purposeTokens = tokens(rawPurpose)
        guard !purpose.isEmpty, !purposeTokens.isEmpty else { return nil }

        let ranked = intentions.compactMap { intention -> PurposeIntentionMatch? in
            let name = normalizedPhrase(intention.name)
            let nameTokens = tokens(intention.name)
            guard !name.isEmpty, !nameTokens.isEmpty else { return nil }

            let score: Double
            if purpose == name {
                score = 1
            } else if purpose.contains(name) || name.contains(purpose) {
                score = 0.94
            } else {
                let intersection = purposeTokens.intersection(nameTokens).count
                guard intersection > 0 else { return nil }
                let nameCoverage = Double(intersection) / Double(nameTokens.count)
                let union = purposeTokens.union(nameTokens).count
                let jaccard = union == 0 ? 0 : Double(intersection) / Double(union)
                score = (nameCoverage * 0.72) + (jaccard * 0.28)
            }

            return PurposeIntentionMatch(intentionID: intention.id, score: score)
        }

        guard let best = ranked.max(by: { $0.score < $1.score }),
              best.score >= minimumScore else {
            return nil
        }
        return best
    }

    private static func normalizedPhrase(_ value: String) -> String {
        tokens(value).sorted().joined(separator: " ")
    }

    private static func tokens(_ value: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "and", "at", "computer", "do", "for", "i", "in", "me",
            "my", "of", "on", "open", "please", "some", "the", "to", "use", "want"
        ]
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let components = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(components.compactMap { component in
            var token = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count > 1, !stopWords.contains(token) else { return nil }
            if token.count > 4, token.hasSuffix("ing") {
                token.removeLast(3)
            } else if token.count > 3, token.hasSuffix("s") {
                token.removeLast()
            }
            return token.isEmpty ? nil : token
        })
    }
}
