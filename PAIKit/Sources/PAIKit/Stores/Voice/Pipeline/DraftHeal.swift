import Foundation

/// How a take's backfilled text finds its way back into wherever it was written — a composer's
/// draft, most often — once it heals after the take has already ended. Deliberately has no append
/// fallback: a healed take's own text, once inserted, must be found and replaced in place or left
/// entirely alone. Appending the whole assembled take a second time is exactly the failure this
/// type exists to make impossible to reach by construction, not merely to avoid by discipline at
/// each call site.
public enum DraftHeal {
    public enum Outcome: Sendable, Equatable {
        /// `previousInsertedText`'s one occurrence in the draft was replaced with `healedText` —
        /// the caller writes this back as the draft's new text.
        case replaced(String)
        /// The take's own previously-inserted text is no longer present verbatim — edited since,
        /// already sent, or the draft cleared. The draft is left exactly as it was; the caller's
        /// job is to say so once (a notification, a Recordings row), never to append.
        case notFound
    }

    /// `previousInsertedText` is what `VoiceTextAssembly.assembledPrefixedText` produced the last
    /// time this take's text was written into `currentDraftText` — the caller's own record of it,
    /// not anything this type stores. An empty `previousInsertedText` is always `.notFound`: a
    /// take that never inserted anything has nothing to find, and an empty string would otherwise
    /// match everywhere.
    public static func heal(currentDraftText: String, previousInsertedText: String, healedText: String) -> Outcome {
        guard !previousInsertedText.isEmpty, let range = currentDraftText.range(of: previousInsertedText) else {
            return .notFound
        }
        var result = currentDraftText
        result.replaceSubrange(range, with: healedText)
        return .replaced(result)
    }
}
