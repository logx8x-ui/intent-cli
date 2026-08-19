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

        testLiveCorrections()
        print("PurposeMatcherSpec passed")
    }

    private static func testLiveCorrections() {
        let firefox = AllowedApp(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
        let anki = AllowedApp(name: "Anki", bundleIdentifier: "net.ankiweb.dtop")
        let messages = AllowedApp(name: "Messages", bundleIdentifier: "com.apple.MobileSMS")
        let apps = [firefox, anki, messages]
        let study = intention(id: "study-live", name: "Study", apps: [firefox, anki])

        let removed = PurposeLiveInterpreter.interpret(
            "I want Firefox and Anki. Oops, remove Anki.",
            apps: apps,
            intentions: [study]
        )
        expect(removed.includedAppBundleIdentifiers == [firefox.bundleIdentifier], "later removal wins")
        expect(removed.excludedAppBundleIdentifiers == [anki.bundleIdentifier], "removed app is explicit")

        let voiceCorrection = PurposeLiveInterpreter.interpret(
            "Use iMessages. Actually take away iMessages.",
            apps: apps,
            intentions: []
        )
        expect(voiceCorrection.includedAppBundleIdentifiers.isEmpty, "take away removes a spoken app")
        expect(
            voiceCorrection.excludedAppBundleIdentifiers == [messages.bundleIdentifier],
            "iMessages resolves to Messages"
        )

        let addedBack = PurposeLiveInterpreter.interpret(
            "Use Firefox and Anki, remove Anki, then add Anki back.",
            apps: apps,
            intentions: []
        )
        expect(
            Set(addedBack.includedAppBundleIdentifiers) == Set([firefox.bundleIdentifier, anki.bundleIdentifier]),
            "add back overrides removal"
        )

        let narrowed = PurposeLiveInterpreter.interpret(
            "Use Firefox and Anki. Actually, just Firefox.",
            apps: apps,
            intentions: []
        )
        expect(narrowed.includedAppBundleIdentifiers == [firefox.bundleIdentifier], "just narrows the app list")
        expect(narrowed.limitsAppsToSelection, "narrowing is carried into session creation")

        let editedIntention = PurposeLiveInterpreter.interpret(
            "Run Study, but remove Anki.",
            apps: apps,
            intentions: [study]
        )
        expect(editedIntention.includedIntentionIDs == [study.id], "saved intention is understood live")
        expect(
            editedIntention.includedAppBundleIdentifiers == [firefox.bundleIdentifier],
            "an app can be removed from a referenced intention"
        )

        let switchedCommand = PurposeLiveInterpreter.interpret(
            "Remove Anki, then use Firefox.",
            apps: apps,
            intentions: []
        )
        expect(switchedCommand.includedAppBundleIdentifiers == [firefox.bundleIdentifier], "new command scope includes Firefox")
        expect(switchedCommand.excludedAppBundleIdentifiers == [anki.bundleIdentifier], "new command scope keeps Anki removed")

        let explicitNegation = PurposeLiveInterpreter.interpret(
            "Use Firefox, but do not add Anki.",
            apps: apps,
            intentions: []
        )
        expect(explicitNegation.includedAppBundleIdentifiers == [firefox.bundleIdentifier], "do not add excludes the named app")
        expect(explicitNegation.excludedAppBundleIdentifiers == [anki.bundleIdentifier], "explicit negation is retained")
    }

    private static func intention(id: String, name: String, apps: [AllowedApp] = []) -> Intention {
        Intention(
            id: id,
            name: name,
            icon: "target",
            colorHex: "#FFFFFF",
            folder: "",
            allowedApps: apps,
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
