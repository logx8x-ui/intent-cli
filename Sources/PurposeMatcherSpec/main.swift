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
        testWebsiteHistory()
        print("PurposeMatcherSpec passed")
    }

    private static func testWebsiteHistory() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-purpose-websites-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PurposeWebsiteHistoryStore(fileURL: fileURL)
        try? store.record(
            urlString: "https://oasis.curtin.edu.au/student?private=query",
            title: "OASIS | Curtin University"
        )
        let entries = store.loadEntries()
        expect(entries.count == 1, "website history stores one normalized local entry")
        expect(entries.first?.value == "oasis.curtin.edu.au", "website history never stores paths or query strings")
        expect(entries.first?.name == "OASIS", "website history keeps a readable website name")
        expect(entries.first?.aliases.contains("oasis curtin") == true, "website history learns useful domain aliases")
    }

    private static func testLiveCorrections() {
        let firefox = AllowedApp(name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
        let anki = AllowedApp(name: "Anki", bundleIdentifier: "net.ankiweb.dtop")
        let messages = AllowedApp(name: "Messages", bundleIdentifier: "com.apple.MobileSMS")
        let remNote = AllowedApp(name: "RemNote", bundleIdentifier: "io.remnote")
        let chatGPT = AllowedApp(name: "ChatGPT", bundleIdentifier: "com.openai.chat")
        let apps = [firefox, anki, messages, remNote, chatGPT]
        let study = intention(
            id: "study-live",
            name: "Study",
            apps: [firefox, anki],
            websites: [.init("github.com", browserBundleIdentifier: firefox.bundleIdentifier)]
        )
        let messagesIntention = intention(
            id: "messages-live",
            name: "Reply to messages",
            apps: [messages]
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
            editedIntention.includedAppBundleIdentifiers == [firefox.bundleIdentifier, anki.bundleIdentifier],
            "a starred intention remains an exact saved session"
        )
        expect(
            editedIntention.includedWebsites.map(\.value) == ["github.com"],
            "a starred intention brings its allowed websites"
        )

        let exclusiveIntention = PurposeLiveInterpreter.interpret(
            "Run *Study with Messages and Instagram on Firefox",
            apps: apps,
            intentions: [study, messagesIntention]
        )
        expect(exclusiveIntention.includedIntentionIDs == [study.id], "the first starred intention is authoritative")
        expect(
            exclusiveIntention.includedAppBundleIdentifiers == [firefox.bundleIdentifier, anki.bundleIdentifier],
            "loose app mentions cannot expand a starred intention"
        )
        expect(
            exclusiveIntention.includedWebsites.map(\.value) == ["github.com"],
            "loose website mentions cannot expand a starred intention"
        )

        let conflictingIntentions = PurposeLiveInterpreter.interpret(
            "Run *Study and *Reply to messages",
            apps: apps,
            intentions: [study, messagesIntention]
        )
        expect(conflictingIntentions.includedIntentionIDs == [study.id], "only one intention remains runnable")
        expect(
            conflictingIntentions.conflictingIntentionIDs == [messagesIntention.id],
            "a second starred intention is reported as a conflict"
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

        let multipleBrowserWebsites = PurposeLiveInterpreter.interpret(
            "I want to use Firefox with YouTube and Instagram",
            apps: apps,
            intentions: []
        )
        expect(
            multipleBrowserWebsites.includedWebsites.map(\.value) == ["youtube.com", "instagram.com"],
            "multiple websites remain attached to the preceding browser"
        )
        expect(
            multipleBrowserWebsites.includedWebsites.allSatisfy {
                $0.browserBundleIdentifier == firefox.bundleIdentifier
            },
            "all websites in a browser phrase share that browser"
        )

        let canonicalBrowserGroup = PurposeLiveInterpreter.canonicalizedDisplayText(
            "I want to use firefox with youtube and instagram",
            apps: apps
        )
        expect(
            canonicalBrowserGroup == "I want to use Firefox(YouTube, Instagram)",
            "browser website phrases become a clear grouped display"
        )
        let groupedInterpretation = PurposeLiveInterpreter.interpret(
            canonicalBrowserGroup,
            apps: apps,
            intentions: []
        )
        expect(
            groupedInterpretation.includedWebsites.map(\.value) == ["youtube.com", "instagram.com"],
            "the grouped display remains fully interpretable"
        )

        let chrome = AllowedApp(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        let multipleBrowsers = PurposeLiveInterpreter.interpret(
            "Use Firefox with YouTube and Instagram, then Google Chrome with Gmail",
            apps: apps + [chrome],
            intentions: []
        )
        expect(
            multipleBrowsers.includedWebsites.first(where: { $0.value == "youtube.com" })?.browserBundleIdentifier
                == firefox.bundleIdentifier,
            "YouTube stays attached to Firefox"
        )
        expect(
            multipleBrowsers.includedWebsites.first(where: { $0.value == "instagram.com" })?.browserBundleIdentifier
                == firefox.bundleIdentifier,
            "Instagram stays attached to Firefox"
        )
        expect(
            multipleBrowsers.includedWebsites.first(where: { $0.value == "mail.google.com" })?.browserBundleIdentifier
                == chrome.bundleIdentifier,
            "Gmail attaches to the later Chrome mention"
        )

        let autocomplete = PurposeLiveInterpreter.intentionAutocompleteCandidates(
            for: "Run *Stu",
            intentions: [study]
        )
        expect(autocomplete.map(\.id) == [study.id], "asterisk autocomplete finds a partial intention")
        let completedMention = PurposeLiveInterpreter.completingIntentionMention(in: "Run *Stu", with: study)
        expect(
            completedMention == "Run * Study",
            "accepting autocomplete inserts the complete starred intention"
        )

        let appWithoutBrowser = PurposeLiveInterpreter.interpret(
            "Use ChatGPT",
            apps: apps,
            intentions: []
        )
        expect(appWithoutBrowser.includedAppBundleIdentifiers == [chatGPT.bundleIdentifier], "an app name resolves to the app")
        expect(appWithoutBrowser.includedWebsites.isEmpty, "a site is not inferred without an explicit browser link")

        let websiteOnBrowser = PurposeLiveInterpreter.interpret(
            "Use ChatGPT on Firefox",
            apps: apps,
            intentions: []
        )
        expect(websiteOnBrowser.includedAppBundleIdentifiers == [firefox.bundleIdentifier], "a browser-linked site does not also add its app")
        expect(websiteOnBrowser.includedWebsites.map(\.value) == ["chatgpt.com"], "the explicitly linked site is recognized")
        expect(
            websiteOnBrowser.includedWebsites.first?.browserBundleIdentifier == firefox.bundleIdentifier,
            "the site keeps its explicit browser"
        )

        let unpairedWebsite = PurposeLiveInterpreter.interpret(
            "Use YouTube",
            apps: apps,
            intentions: []
        )
        expect(unpairedWebsite.includedWebsites.isEmpty, "a standalone website name is not silently assigned to a browser")

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

        let changedBrowserWebsite = PurposeLiveInterpreter.interpret(
            "Use Firefox with YouTube, remove YouTube, then add Instagram.",
            apps: apps,
            intentions: []
        )
        expect(
            changedBrowserWebsite.includedWebsites.map(\.value) == ["instagram.com"],
            "a corrected website keeps the established browser workspace"
        )
        expect(
            changedBrowserWebsite.includedWebsites.first?.browserBundleIdentifier == firefox.bundleIdentifier,
            "a corrected website remains attached to Firefox"
        )

        let wikipedia = PurposeLiveInterpreter.interpret(
            "Use Firefox and Wikipedia",
            apps: apps,
            intentions: []
        )
        expect(wikipedia.includedWebsites.map(\.value) == ["wikipedia.org"], "Wikipedia is recognized after a browser")
        expect(
            wikipedia.includedWebsites.first?.browserBundleIdentifier == firefox.bundleIdentifier,
            "Wikipedia attaches to the preceding browser"
        )

        let oasis = PurposeLiveInterpreter.interpret(
            "Use Firefox for the OASIS student portal for Curtin",
            apps: apps,
            intentions: []
        )
        expect(oasis.includedWebsites.map(\.value) == ["oasis.curtin.edu.au"], "Curtin OASIS speech is recognized")

        let learnedPortal = PurposeKnownWebsite(
            name: "Student Hub",
            value: "students.example.edu",
            aliases: ["student portal", "university student hub"]
        )
        let learnedWebsite = PurposeLiveInterpreter.interpret(
            "Use Firefox and the student portal",
            apps: apps,
            intentions: [],
            knownWebsites: [learnedPortal]
        )
        expect(
            learnedWebsite.includedWebsites.map(\.value) == ["students.example.edu"],
            "locally learned website aliases participate in live recognition"
        )

        let savedPortalIntention = intention(
            id: "portal",
            name: "Portal",
            apps: [firefox],
            websites: [.init("portal.example.edu", browserBundleIdentifier: firefox.bundleIdentifier)]
        )
        let savedPortal = PurposeLiveInterpreter.interpret(
            "Use Firefox and portal",
            apps: apps,
            intentions: [savedPortalIntention]
        )
        expect(
            savedPortal.includedWebsites.map(\.value) == ["portal.example.edu"],
            "websites already saved in intentions become recognizable vocabulary"
        )

        let explicitDesktopApp = PurposeLiveInterpreter.interpret(
            "Use Firefox with YouTube, then add the ChatGPT app",
            apps: apps,
            intentions: []
        )
        expect(
            explicitDesktopApp.includedAppBundleIdentifiers.contains(chatGPT.bundleIdentifier),
            "an explicit app request remains an application after a browser workspace"
        )
        expect(
            !explicitDesktopApp.includedWebsites.contains(where: { $0.value == "chatgpt.com" }),
            "an explicit app request is not converted into a website"
        )

        let speechAlias = PurposeLiveInterpreter.interpret(
            "Use ram note",
            apps: apps,
            intentions: []
        )
        expect(speechAlias.includedAppBundleIdentifiers == [remNote.bundleIdentifier], "speech alias resolves RemNote")

        let vagueStudy = PurposeLiveInterpreter.interpret(
            "I want to study",
            apps: apps,
            intentions: [study]
        )
        expect(
            PurposeLiveInterpreter.clarificationPrompt(for: "I want to study", interpretation: vagueStudy)
                == "Okay, awesome. What apps or websites do you want to use to study?",
            "vague study requests ask for the resources needed"
        )
        expect(
            PurposeLiveInterpreter.clarificationPrompt(for: "Study with Anki", interpretation: editedIntention) == nil,
            "resolved requests do not ask a follow-up"
        )

        expect(
            PurposeLiveInterpreter.incrementalSpeechAppend(
                previous: "Use Firefox",
                current: "Use Firefox and Anki"
            ) == "and Anki",
            "speech updates append only newly recognized words"
        )
        expect(
            PurposeLiveInterpreter.incrementalSpeechAppend(
                previous: "Use Firefox and Anki",
                current: "Use Firefox"
            ).isEmpty,
            "shorter recognition revisions never restore deleted text"
        )
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
