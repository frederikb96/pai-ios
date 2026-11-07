import Foundation
import Observation

/// What the owner has done in one list of decisions (a session's pin, or one session's group in
/// the Decisions app) and not sent yet: which lines are open, which answer is picked for each,
/// the free text being written. Swift port of the local state in `DecisionList.tsx`; a tap picks
/// without sending, and Send turns every pick into one request.
@MainActor
@Observable
public final class DecisionListState {
    public private(set) var expanded: Set<Int> = []
    public private(set) var picked: [Int: String] = [:]
    /// The decision whose own words are being written.
    public private(set) var writing: Int?
    public var ownWords = ""
    public private(set) var isSending = false
    public private(set) var errorMessage: String?

    public init() {}

    public func toggleExpanded(_ number: Int) {
        if expanded.contains(number) { expanded.remove(number) } else { expanded.insert(number) }
    }

    /// Picking the answer already picked takes it back.
    public func pick(_ number: Int, _ text: String) {
        if picked[number] == text { picked[number] = nil } else { picked[number] = text }
    }

    /// Opens or closes the free-text field, seeded with an earlier own-words pick.
    public func toggleWriting(for decision: Decision) {
        if writing == decision.number {
            writing = nil
            return
        }
        writing = decision.number
        if let choice = picked[decision.number], !decision.options.contains(choice) {
            ownWords = choice
        } else {
            ownWords = ""
        }
    }

    public var canUseOwnWords: Bool { !ownWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func commitOwnWords() {
        guard let number = writing, canUseOwnWords else { return }
        picked[number] = ownWords.trimmingCharacters(in: .whitespacesAndNewlines)
        writing = nil
    }

    public func clearPicks() {
        picked = [:]
    }

    public func pickAllRecommended(_ decisions: [Decision]) {
        picked = Dictionary(uniqueKeysWithValues: decisions.map { ($0.number, $0.recommendation) })
    }

    /// The picks that still belong to an open decision of `decisions`, by number, each carrying
    /// the `updatedAt` it was shown with. A decision answered elsewhere meanwhile has left the list
    /// and its pick is not sent.
    public func pendingAnswers(for decisions: [Decision]) -> [DecisionAnswer] {
        decisions.sorted { $0.number < $1.number }.compactMap { decision in
            picked[decision.number].map {
                DecisionAnswer(number: decision.number, answer: $0, updatedAt: decision.updatedAt)
            }
        }
    }

    public func send(sessionId: String, decisions: [Decision], store: DecisionsStore) async {
        let answers = pendingAnswers(for: decisions)
        guard !answers.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await store.answer(sessionId: sessionId, answers: answers)
            picked = [:]
        } catch {
            errorMessage = Self.message(for: error, fallback: "Could not send the answers")
        }
    }

    public func withdraw(_ decision: Decision, store: DecisionsStore) async {
        errorMessage = nil
        do {
            try await store.withdraw(decision)
            picked[decision.number] = nil
        } catch {
            errorMessage = Self.message(for: error, fallback: "Could not dismiss this decision")
        }
    }

    /// The server's own words for a refusal (its 409 names which decision changed), else the
    /// fallback.
    static func message(for error: Error, fallback: String) -> String {
        if let error = error as? PaiError {
            if case .http(409, _) = error {
                return "One of these was answered or withdrawn meanwhile. Nothing was sent."
            }
            return error.userMessage
        }
        return fallback
    }
}
