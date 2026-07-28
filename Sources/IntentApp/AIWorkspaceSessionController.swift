import Foundation
import IntentCore

@MainActor
final class AIWorkspaceSessionController: ObservableObject {
    @Published var sessions: [AIWorkspaceSession] = []
    @Published var activeSessionID: String?
    @Published var clarificationMessage: String?

    private let store: AIHistoryStore

    init(store: AIHistoryStore = AIHistoryStore()) {
        self.store = store
        self.sessions = store.load()
        self.activeSessionID = sessions.first?.id
    }

    var activeSession: AIWorkspaceSession? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    @discardableResult
    func startNewDraft() -> AIWorkspaceSession {
        var session = AIWorkspaceSession()
        session.refreshTitle()
        store.upsert(session, into: &sessions)
        persist()
        activeSessionID = session.id
        clarificationMessage = nil
        return session
    }

    func resume(id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        activeSessionID = id
        clarificationMessage = nil
    }

    func delete(id: String) {
        store.delete(id: id, from: &sessions)
        persist()
        if activeSessionID == id {
            activeSessionID = sessions.first?.id
        }
    }

    func ensureActiveSession() -> AIWorkspaceSession {
        if let active = activeSession {
            return active
        }
        return startNewDraft()
    }

    func recordUserPrompt(
        _ prompt: String,
        draft: Intention?,
        targetIntentionID: String?
    ) {
        var session = ensureActiveSession()
        session.messages.append(.init(role: .user, content: prompt))
        if let draft { session.draft = draft }
        if let targetIntentionID { session.targetIntentionID = targetIntentionID }
        session.status = .draft
        session.refreshTitle()
        session.touch()
        store.upsert(session, into: &sessions)
        persist()
        activeSessionID = session.id
    }

    func recordAssistantResult(
        summary: String,
        draft: Intention,
        targetIntentionID: String?
    ) {
        var session = ensureActiveSession()
        session.messages.append(.init(role: .assistant, content: summary))
        session.draft = draft
        if let targetIntentionID {
            session.targetIntentionID = targetIntentionID
        }
        session.status = .draft
        session.refreshTitle()
        session.touch()
        store.upsert(session, into: &sessions)
        persist()
    }

    func recordDraftEdit(_ draft: Intention?) {
        var session = ensureActiveSession()
        session.draft = draft
        session.refreshTitle()
        session.touch()
        store.upsert(session, into: &sessions)
        persist()
    }

    func recordTargetChange(_ targetIntentionID: String?) {
        var session = ensureActiveSession()
        session.targetIntentionID = targetIntentionID
        session.touch()
        store.upsert(session, into: &sessions)
        persist()
    }

    func markFinalised(draft: Intention, targetIntentionID: String?) {
        var session = ensureActiveSession()
        session.draft = draft
        session.targetIntentionID = targetIntentionID
        session.status = .applied
        session.finalisedAt = Date()
        session.refreshTitle()
        session.touch()
        store.upsert(session, into: &sessions)
        persist()
    }

    func resolveTarget(
        for prompt: String,
        intentions: [Intention],
        currentTarget: String?
    ) -> (targetID: String?, intention: Intention?, blocked: Bool) {
        clarificationMessage = nil
        switch AIIntentionMentionResolver.resolvePrimaryTarget(in: prompt, intentions: intentions) {
        case .ambiguous(let matches):
            let names = matches.map(\.name).joined(separator: ", ")
            clarificationMessage = "Which intention did you mean: \(names)?"
            return (currentTarget, intentions.first { $0.id == currentTarget }, true)
        case .missing(_, let displayName):
            clarificationMessage = "“\(displayName)” no longer exists. Choose another intention or start a new draft."
            return (nil, nil, true)
        case .resolved(let intentionID, _):
            let intention = intentions.first { $0.id == intentionID }
            return (intentionID, intention, false)
        case .none:
            if let currentTarget,
               let intention = intentions.first(where: { $0.id == currentTarget }) {
                return (currentTarget, intention, false)
            }
            return (nil, nil, false)
        }
    }

    private func persist() {
        try? store.save(sessions)
    }
}
