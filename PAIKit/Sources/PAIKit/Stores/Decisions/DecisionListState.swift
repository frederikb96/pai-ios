import Foundation
import Observation

/// What one surface showing a session's decisions (the pin, one session's group in the Decisions
/// app, one card inside a reply) holds for itself: which lines are open, the free text being
/// written, whether its Send is in flight and what the last attempt said. The picks themselves are
/// the session's, in ``DecisionsStore/picks``, so every surface sends the same set. Swift port of
/// the local state in `DecisionList.tsx`.
@MainActor
@Observable
public final class DecisionListState {
    public private(set) var expanded: Set<Int> = []
    /// The decision whose own words are being written.
    public private(set) var writing: Int?
    public var ownWords = ""
    public private(set) var isSending = false
    public private(set) var errorMessage: String?

    public init() {}

    public func toggleExpanded(_ number: Int) {
        if expanded.contains(number) { expanded.remove(number) } else { expanded.insert(number) }
    }

    /// Opens or closes the free-text field, seeded with an earlier own-words pick.
    public func toggleWriting(for decision: Decision, store: DecisionsStore) {
        if writing == decision.number {
            writing = nil
            return
        }
        writing = decision.number
        ownWords = Self.ownWordsSeed(
            for: decision, picked: store.picked(sessionId: decision.sessionId, number: decision.number))
    }

    /// What the free-text field starts with: an earlier pick that is none of the offered options.
    public nonisolated static func ownWordsSeed(for decision: Decision, picked: String?) -> String {
        guard let picked, !decision.options.contains(picked) else { return "" }
        return picked
    }

    public var canUseOwnWords: Bool { !ownWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func commitOwnWords(for decision: Decision, store: DecisionsStore) {
        guard writing == decision.number, canUseOwnWords else { return }
        Self.useOwnWords(ownWords, for: decision, store: store)
        writing = nil
    }

    /// Picks `text` as the answer to `decision`, unless it is already the pick: picking the pick
    /// again would take it back.
    public static func useOwnWords(_ text: String, for decision: Decision, store: DecisionsStore) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            store.picked(sessionId: decision.sessionId, number: decision.number) != trimmed
        else { return }
        store.pick(trimmed, for: decision)
    }

    /// Sends every answer picked for the session, from whichever surface it was picked on.
    public func send(sessionId: String, store: DecisionsStore) async {
        let answers = store.pendingAnswers(sessionId: sessionId)
        guard !answers.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await store.answer(sessionId: sessionId, answers: answers)
        } catch {
            errorMessage = Self.message(for: error, fallback: "Could not send the answers")
        }
    }

    public func withdraw(_ decision: Decision, store: DecisionsStore) async {
        errorMessage = nil
        do {
            try await store.withdraw(decision)
        } catch {
            errorMessage = Self.message(for: error, fallback: "Could not dismiss this decision")
        }
    }

    /// The server's own words for a refusal (its 409 names which decision changed), else the
    /// fallback.
    public static func message(for error: Error, fallback: String) -> String {
        if let error = error as? PaiError {
            if case .http(409, _) = error {
                return "One of these was answered, withdrawn or changed meanwhile. Nothing was sent."
            }
            return error.userMessage
        }
        return fallback
    }
}
