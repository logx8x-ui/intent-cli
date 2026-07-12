import AppKit
import Foundation
import IntentCore
import IntentLock

@MainActor
protocol IntentOverlayPresenting: AnyObject {
    func showOverlay(animated: Bool)
    func hideOverlay(animated: Bool)
    func toggleOverlay()
}

@MainActor
final class IntentAppModel: ObservableObject {
    @Published var intentions: [Intention] = []
    @Published var selectedID: String?
    @Published var activeSessionName: String?
    @Published var pendingFriction: PendingFriction?
    @Published var errorMessage: String?
    @Published var installedApps: [InstalledApp] = []

    weak var overlayPresenter: IntentOverlayPresenting?

    private let store = IntentionStore()
    private let browserRulesStore = ActiveBrowserRulesStore()
    private let browserGuardHeartbeatStore = BrowserGuardHeartbeatStore()
    private let browserGuardStateStore = BrowserGuardStateStore()
    private var pendingStartIntention: Intention?
    private var remainingFrictions: [FrictionNode] = []
    private var activeLock: FocusLock?

    var selectedIntention: Intention? {
        guard let selectedID else { return intentions.first }
        return intentions.first { $0.id == selectedID }
    }

    var hasActiveSession: Bool { activeSessionName != nil }

    func load() {
        if installedApps.isEmpty {
            installedApps = AppCatalog.load()
        }

        do {
            intentions = try store.load()
            selectedID = selectedID ?? intentions.first?.id
            try store.save(intentions)
        } catch {
            errorMessage = "Could not load intentions: \(error)"
            intentions = DefaultIntentions.make()
            selectedID = intentions.first?.id
        }
    }

    func save() {
        guard !hasActiveSession else { return }
        do {
            try store.save(intentions)
        } catch {
            errorMessage = "Could not save intentions: \(error)"
        }
    }

    @discardableResult
    func createIntention(at position: GraphPoint) -> String {
        let intention = Intention(
            name: "New intention",
            icon: "target",
            colorHex: "#F5F5F7",
            folder: "",
            allowedApps: [],
            allowedWebsites: [],
            startupActions: [],
            restrictions: .init(),
            graphPosition: position
        )
        intentions.append(intention)
        selectedID = intention.id
        save()
        return intention.id
    }

    func deleteIntention(id: String) {
        guard !hasActiveSession else { return }
        intentions.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = intentions.first?.id
        }
        save()
    }

    func updateIntention(_ intention: Intention) {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == intention.id }) else {
            return
        }
        intentions[index] = intention
        save()
    }

    func mutateIntention(id: String, _ mutation: (inout Intention) -> Void) {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutation(&intentions[index])
        save()
    }

    func moveIntention(id: String, to position: GraphPoint, persist: Bool) {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == id }) else {
            return
        }
        intentions[index].graphPosition = position
        if persist { save() }
    }

    func moveRestriction(intentionID: String, nodeID: String, to position: GraphPoint, persist: Bool) {
        guard !hasActiveSession,
              let intentionIndex = intentions.firstIndex(where: { $0.id == intentionID }),
              let nodeIndex = intentions[intentionIndex].restrictionNodes.firstIndex(where: { $0.id == nodeID }) else {
            return
        }
        intentions[intentionIndex].restrictionNodes[nodeIndex].position = position
        if persist { save() }
    }

    func moveFriction(intentionID: String, nodeID: String, to position: GraphPoint, persist: Bool) {
        guard !hasActiveSession,
              let intentionIndex = intentions.firstIndex(where: { $0.id == intentionID }),
              let nodeIndex = intentions[intentionIndex].frictionNodes.firstIndex(where: { $0.id == nodeID }) else {
            return
        }
        intentions[intentionIndex].frictionNodes[nodeIndex].position = position
        if persist { save() }
    }

    @discardableResult
    func addRestriction(to intentionID: String, at position: GraphPoint) -> String? {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == intentionID }) else {
            return nil
        }
        let node = RestrictionNode(kind: .allowBrowserSearches, position: position)
        intentions[index].restrictionNodes.append(node)
        selectedID = intentionID
        save()
        return node.id
    }

    @discardableResult
    func addFriction(to intentionID: String, at position: GraphPoint) -> String? {
        guard !hasActiveSession,
              let index = intentions.firstIndex(where: { $0.id == intentionID }) else {
            return nil
        }
        let node = FrictionNode(
            friction: .typedPhrase("I want to do this right now"),
            position: position
        )
        intentions[index].frictionNodes.append(node)
        selectedID = intentionID
        save()
        return node.id
    }

    func requestStart(_ intention: Intention) {
        guard !hasActiveSession else {
            errorMessage = "Finish the current intention before starting another one."
            return
        }
        guard !intention.allowedApps.isEmpty else {
            errorMessage = "Add at least one allowed app before starting this intention."
            return
        }
        let unsupportedBrowsers = intention.allowedApps.filter {
            $0.isBrowser && $0.bundleIdentifier != "org.mozilla.firefox"
        }
        if !unsupportedBrowsers.isEmpty {
            let names = unsupportedBrowsers.map(\.name).joined(separator: ", ")
            errorMessage = "Browser locking currently supports Firefox only. Replace \(names) with Firefox before starting this intention."
            return
        }

        let frictions = intention.orderedFrictionNodes
        guard !frictions.isEmpty else {
            start(intention)
            return
        }

        pendingStartIntention = intention
        remainingFrictions = frictions
        presentNextFriction()
    }

    func requestStart(intentionID: String) {
        guard let intention = intentions.first(where: { $0.id == intentionID }) else {
            errorMessage = "Could not find that intention."
            return
        }
        selectedID = intention.id
        requestStart(intention)
    }

    func submitFriction(_ input: String) {
        guard let pendingFriction else { return }
        guard pendingFriction.validate(input) else {
            errorMessage = "That friction check is not complete yet."
            return
        }
        completeCurrentFriction()
    }

    func completeCurrentFriction() {
        guard pendingFriction != nil else { return }
        self.pendingFriction = nil
        if !remainingFrictions.isEmpty {
            remainingFrictions.removeFirst()
        }

        if remainingFrictions.isEmpty {
            guard let intention = pendingStartIntention else { return }
            pendingStartIntention = nil
            start(intention)
        } else {
            presentNextFriction()
        }
    }

    func cancelFriction() {
        pendingFriction = nil
        pendingStartIntention = nil
        remainingFrictions = []
    }

    func endActiveSession() {
        activeLock?.stop()
    }

    func showOverlay() {
        overlayPresenter?.showOverlay(animated: true)
    }

    func hideOverlay() {
        overlayPresenter?.hideOverlay(animated: true)
    }

    func toggleOverlay() {
        overlayPresenter?.toggleOverlay()
    }

    private func presentNextFriction() {
        guard let intention = pendingStartIntention,
              let node = remainingFrictions.first else {
            return
        }
        let completed = intention.frictionNodes.count - remainingFrictions.count
        pendingFriction = PendingFriction(
            intentionID: intention.id,
            intentionName: intention.name,
            node: node,
            step: completed + 1,
            totalSteps: intention.frictionNodes.count
        )
    }

    private func start(_ intention: Intention) {
        if requiresFirefoxGuard(intention),
           !browserGuardHeartbeatStore.isFresh(maxAge: 5) {
            errorMessage = "Firefox browser locking is not connected. Load the Intent Browser Guard extension in Firefox, then start this intention again."
            return
        }

        if requiresFirefoxGuard(intention),
           !browserGuardStateStore.isEnabled() {
            errorMessage = "Firefox browser locking is turned off. Open Intent Browser Guard in Firefox and switch it on, then start this intention again."
            return
        }

        let spec = FocusSessionSpec.make(for: intention)
        let firefoxWebsites = intention.websites(for: "org.mozilla.firefox").map(\.value)
        let rules = ActiveBrowserRules(
            active: true,
            // A non-matching sentinel keeps already-installed Browser Guard 0.1.3 builds strict
            // when Firefox is allowed but the intention has no website spikes.
            allowedWebsites: firefoxWebsites.isEmpty ? ["intent.invalid"] : firefoxWebsites,
            blockTabSwitching: true,
            blockNavigation: true,
            blockNewTabs: !intention.browserSearchesAllowed,
            allowGoogleSearchTabs: intention.browserSearchesAllowed
        )

        do {
            try browserRulesStore.write(rules)
        } catch {
            errorMessage = "Could not write browser rules: \(error)"
            return
        }

        let lock = FocusLock(spec: spec)
        activeLock = lock
        activeSessionName = intention.name
        overlayPresenter?.hideOverlay(animated: true)

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
                    self.activeLock = nil
                    self.activeSessionName = nil
                    self.overlayPresenter?.showOverlay(animated: true)
                }
            }

            do {
                try lock.run()
            } catch {
                Task { @MainActor in
                    self.errorMessage = "Could not start session: \(error)"
                }
            }
        }
    }

    private func requiresFirefoxGuard(_ intention: Intention) -> Bool {
        intention.allowedApps.contains { $0.bundleIdentifier == "org.mozilla.firefox" }
    }
}

struct PendingFriction: Identifiable {
    let id = UUID()
    let intentionID: String
    let intentionName: String
    let node: FrictionNode
    let step: Int
    let totalSteps: Int

    var friction: Friction { node.friction }

    func validate(_ input: String) -> Bool {
        switch friction {
        case .none, .countdown:
            return true
        case .typedPhrase(let phrase):
            return input == phrase
        case .reasonPrompt:
            return !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .taskChecklist:
            return input == "done"
        case .timeBudget(let minutes):
            return input == "\(minutes)"
        }
    }
}
