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
        let remNote = AllowedApp(name: "RemNote", bundleIdentifier: "io.remnote")
        let apps = [firefox, anki, messages, remNote]
        let study = intention(
            id: "study-live",
            name: "Study",
            apps: [firefox, anki],
            websites: [.init("github.com", browserBundleIdentifier: firefox.bundleIdentifier)]
        )

        let empty = PurposeLiveInterpreter.interpret("", apps: apps, intentions: [study])
        expect(empty.includedAppBundleIdentifiers.isEmpty, "clearing text clears suggested apps")
        expect(empty.includedWebsites.isEmpty, "clearing text clears suggested websites")
        expect(empty.includedIntentionIDs.isEmpty, "clearing text clears suggested intentions")

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
            "Run *Study, but remove Anki.",
            apps: apps,
            intentions: [study]
        )
        expect(editedIntention.includedIntentionIDs == [study.id], "starred intention is understood live")
        expect(
            editedIntention.includedAppBundleIdentifiers == [firefox.bundleIdentifier],
            "an app can be removed from a referenced intention"
        )
        expect(
            editedIntention.includedWebsites.map(\.value) == ["github.com"],
            "a starred intention brings its allowed websites"
        )

        let unstarredIntention = PurposeLiveInterpreter.interpret(
            "Run Study",
            apps: apps,
            intentions: [study]
        )
        expect(unstarredIntention.includedIntentionIDs.isEmpty, "unstarred intention names are not pinged")

        let spokenStar = PurposeLiveInterpreter.interpret(
            "Run astrix Study",
            apps: apps,
            intentions: [study]
        )
        expect(spokenStar.includedIntentionIDs == [study.id], "spoken asterisk pings an intention")

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

        let browserAndWebsite = PurposeLiveInterpreter.interpret(
            "Add Firefox with YouTube",
            apps: apps,
            intentions: []
        )
        expect(browserAndWebsite.includedAppBundleIdentifiers == [firefox.bundleIdentifier], "browser is recognized")
        expect(browserAndWebsite.includedWebsites.map(\.value) == ["youtube.com"], "website is recognized")
        expect(
            browserAndWebsite.includedWebsites.first?.browserBundleIdentifier == firefox.bundleIdentifier,
            "website is assigned to the mentioned browser"
        )

        let removedWebsite = PurposeLiveInterpreter.interpret(
            "Add Firefox with YouTube. Actually remove YouTube.",
            apps: apps,
            intentions: []
        )
        expect(removedWebsite.includedAppBundleIdentifiers == [firefox.bundleIdentifier], "removing a site keeps its browser")
        expect(removedWebsite.includedWebsites.isEmpty, "later website removal wins")
        expect(removedWebsite.excludedWebsites.map(\.value) == ["youtube.com"], "removed website is explicit")

        let websiteAddedBack = PurposeLiveInterpreter.interpret(
            "Use Firefox with YouTube, remove YouTube, then add YouTube back.",
            apps: apps,
            intentions: []
        )
        expect(websiteAddedBack.includedWebsites.map(\.value) == ["youtube.com"], "website can be added back")

        let speechAlias = PurposeLiveInterpreter.interpret(
            "Use ram note",
            apps: apps,
            intentions: []
        )
        expect(speechAlias.includedAppBundleIdentifiers == [remNote.bundleIdentifier], "speech alias resolves RemNote")
    }

    private static func intention(
        id: String,
        name: String,
        apps: [AllowedApp] = [],
        websites: [AllowedWebsite] = []
    ) -> Intention {
        Intention(
            id: id,
            name: name,
            icon: "target",
            colorHex: "#FFFFFF",
            folder: "",
            allowedApps: apps,
            allowedWebsites: websites,
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
