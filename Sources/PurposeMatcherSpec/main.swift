import Darwin
import Foundation
import IntentCore

@main
struct PurposeMatcherSpec {
    static func main() {
        let reply = intention(id: "reply", name: "Reply to messages")
        let study = intention(id: "study", name: "Data Science")

        let replyMatch = PurposeIntentionMatcher.bestMatch(
            for: "I want to reply to my messages",
            in: [study, reply]
        )
        expect(replyMatch?.intentionID == reply.id, "natural request matches Reply to messages")

        let unrelated = PurposeIntentionMatcher.bestMatch(
            for: "Edit a video",
            in: [reply]
        )
        expect(unrelated == nil, "unrelated purpose does not force a match")

        let generatedMatch = PurposeIntentionMatcher.bestMatch(
            for: "Data science Work on my statistics assignment",
            in: [study],
            minimumScore: 0.88
        )
        expect(generatedMatch?.intentionID == study.id, "AI wording resolves to a saved intention")

        print("PurposeMatcherSpec passed")
    }

    private static func intention(id: String, name: String) -> Intention {
        Intention(
            id: id,
            name: name,
            icon: "target",
            colorHex: "#FFFFFF",
            folder: "",
            allowedApps: [],
            allowedWebsites: [],
            startupActions: [],
            restrictions: .init()
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("PurposeMatcherSpec failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
