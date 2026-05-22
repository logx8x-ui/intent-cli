import AppKit
import Foundation
import IntentCore
import IntentLock

@MainActor
final class IntentAppModel: ObservableObject {
    @Published var intentions: [Intention] = []
    @Published var selectedID: String?
    @Published var activeSessionName: String?
    @Published var pendingFriction: PendingFriction?
    @Published var errorMessage: String?
    @Published var installedApps: [InstalledApp] = []
    @Published var isRunnerPresented = false

    private let store = IntentionStore()
    private let browserRulesStore = ActiveBrowserRulesStore()
    private let browserGuardHeartbeatStore = BrowserGuardHeartbeatStore()
    private let browserGuardStateStore = BrowserGuardStateStore()

    var selectedIntention: Intention? {
        guard let selectedID else { return intentions.first }
        return intentions.first { $0.id == selectedID }
    }

    func load() {
        if installedApps.isEmpty {
            installedApps = AppCatalog.load()
        }

        do {
            intentions = try store.load()
            selectedID = selectedID ?? intentions.first?.id
        } catch {
            errorMessage = "Could not load intentions: \(error)"
            intentions = DefaultIntentions.make()
            selectedID = intentions.first?.id
        }
    }

    func save() {
        do {
            try store.save(intentions)
        } catch {
            errorMessage = "Could not save intentions: \(error)"
        }
    }

    func createIntention() {
        let intention = Intention(
            name: "New intention",
            icon: "target",
            colorHex: "#4B5563",
            folder: "Custom",
            allowedApps: [],
            allowedWebsites: [],
            startupActions: [],
            restrictions: .init()
        )
        intentions.append(intention)
        selectedID = intention.id
        save()
    }

    func deleteSelectedIntention() {
        guard let selectedID else { return }
        intentions.removeAll { $0.id == selectedID }
        self.selectedID = intentions.first?.id
        save()
    }

    func updateSelected(_ intention: Intention) {
        guard let index = intentions.firstIndex(where: { $0.id == intention.id }) else { return }
        intentions[index] = intention
        save()
    }

    func requestStart(_ intention: Intention) {
        switch intention.friction {
        case .none:
            start(intention)
        case .typedPhrase(let phrase):
            pendingFriction = PendingFriction(intention: intention, prompt: "Type exactly:", expectedValue: phrase)
        case .countdown(let seconds):
            pendingFriction = PendingFriction(intention: intention, prompt: "Wait \(seconds) seconds, then type start.", expectedValue: "start")
        case .reasonPrompt(let prompt):
            pendingFriction = PendingFriction(intention: intention, prompt: prompt, expectedValue: nil)
        case .taskChecklist(let tasks):
            pendingFriction = PendingFriction(intention: intention, prompt: tasks.joined(separator: "\n"), expectedValue: "done")
        case .timeBudget(let minutes):
            pendingFriction = PendingFriction(intention: intention, prompt: "Type \(minutes) to confirm this time budget.", expectedValue: "\(minutes)")
        }
    }

    func requestStart(intentionID: String) {
        guard let intention = intentions.first(where: { $0.id == intentionID }) else {
            errorMessage = "Could not find that intention."
            return
        }
        selectedID = intention.id
        requestStart(intention)
    }

    func showRunner() {
        if intentions.isEmpty {
            load()
        }
        NSApp.activate(ignoringOtherApps: true)
        isRunnerPresented = true
    }

    func submitFriction(_ input: String) {
        guard let pendingFriction else { return }
        if pendingFriction.validate(input) {
            self.pendingFriction = nil
            start(pendingFriction.intention)
        } else {
            errorMessage = "Friction check did not match."
        }
    }

    func start(_ intention: Intention) {
        if requiresFirefoxGuard(intention),
           !browserGuardHeartbeatStore.isFresh(maxAge: 5) {
            errorMessage = "Firefox browser locking is not connected. Load the Intent Browser Guard extension in Firefox, then start this intention again."
            return
        }

        if requiresFirefoxGuard(intention),
           !browserGuardStateStore.isEnabled() {
            errorMessage = "Firefox browser locking is turned off. Open the Intent Browser Guard extension in Firefox and switch it on, then start this intention again."
            return
        }

        let spec = FocusSessionSpec.make(for: intention)
        let rules = ActiveBrowserRules(
            active: true,
            allowedWebsites: intention.allowedWebsites.map(\.value),
            blockTabSwitching: intention.restrictions.blockBrowserTabSwitching,
            blockNavigation: intention.restrictions.blockBrowserNavigation,
            blockNewTabs: intention.restrictions.blockNewBrowserTabs,
            allowGoogleSearchTabs: intention.restrictions.allowGoogleSearchTabs
        )

        do {
            try browserRulesStore.write(rules)
        } catch {
            errorMessage = "Could not write browser rules: \(error)"
            return
        }

        activeSessionName = intention.name
        Thread.detachNewThread {
            let renewalTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            renewalTimer.schedule(deadline: .now() + 1, repeating: 1)
            renewalTimer.setEventHandler {
                try? ActiveBrowserRulesStore().write(rules.refreshed())
            }
            renewalTimer.resume()

            defer {
                renewalTimer.cancel()
                try? ActiveBrowserRulesStore().clear()
                Task { @MainActor in
                    self.activeSessionName = nil
                }
            }

            do {
                try FocusLock(spec: spec).run()
            } catch {
                Task { @MainActor in
                    self.errorMessage = "Could not start session: \(error)"
                }
            }
        }
    }

    private func requiresFirefoxGuard(_ intention: Intention) -> Bool {
        let usesFirefox = intention.allowedApps.contains { $0.bundleIdentifier == "org.mozilla.firefox" }
        let browserRestrictionsEnabled =
            intention.restrictions.blockBrowserTabSwitching ||
            intention.restrictions.blockBrowserNavigation ||
            intention.restrictions.blockNewBrowserTabs ||
            intention.restrictions.allowGoogleSearchTabs
        return usesFirefox && browserRestrictionsEnabled
    }
}

struct PendingFriction: Identifiable {
    let id = UUID()
    let intention: Intention
    let prompt: String
    let expectedValue: String?

    func validate(_ input: String) -> Bool {
        if let expectedValue {
            return input == expectedValue
        }
        return !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
