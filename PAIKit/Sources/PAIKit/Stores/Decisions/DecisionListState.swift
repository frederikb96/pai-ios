import Foundation
import Observation

/// What one surface showing a session's decisions (the pin, one session's group in the Decisions
/// app) holds for itself: which lines are open, the free text being written, whether its Send is
/// in flight and what the last attempt said. The picks themselves are the session's, in
/// ``DecisionsStore/picks``, so every surface answers with the same set. Swift port of the local
/// state in `DecisionList.tsx`.
///
/// Other… is an answer like the options: choosing it drops the option picked before, it reads as
/// selected, and the text written is the pick as it stands, so an empty text is no pick.
@MainActor
@Observable
public final class DecisionListState {
    public private(set) var expanded: Set<Int> = []
    /// The decisions whose Other… was chosen here and whose text field is therefore open.
    public private(set) var writing: Set<Int> = []
    /// The text of each decision's field as typed, untrimmed: the pick holds it trimmed, and a
    /// field that followed the pick would swallow a space typed at the end of a word.
    private var ownWords: [Int: String] = [:]
    public private(set) var isSending = false
    public private(set) var errorMessage: String?

    public init() {}

    public func toggleExpanded(_ number: Int) {
        if expanded.contains(number) { expanded.remove(number) } else { expanded.insert(number) }
    }

    /// Whether Other… is the chosen answer: chosen here, or an own-words pick made on another
    /// surface.
    public func isOtherChosen(_ decision: Decision, store: DecisionsStore) -> Bool {
        writing.contains(decision.number) || store.ownWordsPick(for: decision) != nil
    }

    /// What the field shows: what was typed here, else an own-words pick made elsewhere.
    public func ownWordsText(for decision: Decision, store: DecisionsStore) -> String {
        ownWords[decision.number] ?? store.ownWordsPick(for: decision) ?? ""
    }

    public func setOwnWords(_ text: String, for decision: Decision, store: DecisionsStore) {
        ownWords[decision.number] = text
        store.setPick(text, for: decision)
    }

    /// Chooses Other… with the text held so far, which replaces the option picked before (an
    /// empty text leaves no pick), or deselects it when it is already chosen.
    public func toggleOther(_ decision: Decision, store: DecisionsStore) {
        if isOtherChosen(decision, store: store) {
            writing.remove(decision.number)
            if store.ownWordsPick(for: decision) != nil { store.setPick("", for: decision) }
            return
        }
        writing.insert(decision.number)
        store.setPick(ownWords[decision.number] ?? "", for: decision)
    }

    /// Picks an option, which closes Other…; picking the picked one again takes it back.
    public func choose(_ option: String, for decision: Decision, store: DecisionsStore) {
        writing.remove(decision.number)
        store.pick(option, for: decision)
    }

    /// Other… where a field cannot grow in place (inside a transcript row, which is measured
    /// before it is drawn): the owner's words come from a prompt and are picked when it is
    /// confirmed. Empty words clear an own-words pick and leave an option pick alone.
    public static func useOwnWords(_ text: String, for decision: Decision, store: DecisionsStore) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && store.ownWordsPick(for: decision) == nil { return }
        store.setPick(trimmed, for: decision)
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
