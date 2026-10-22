import Foundation

/// What the composer shows and offers around `SkillMentions`: the row above the field, the
/// completions in the keyboard bar, and when each stays silent.
public enum SkillComposer {
    public struct RowItem: Equatable, Identifiable, Sendable {
        public let kind: SkillMentions.Kind
        public let token: String
        public let name: String

        public var id: String { kind.rawValue + ":" + token }

        /// The chip's text: the leading chain is marked as running, a near miss as a question.
        public var label: String {
            switch kind {
            case .runs: return "\u{25B6} /\(name)"
            case .mention: return "/\(name)"
            case .nearMiss: return "did you mean /\(name)?"
            }
        }

        public var isFix: Bool { kind == .nearMiss }
    }

    /// The skills the text names, in order. Empty while a live take owns the box (it rewrites
    /// the text constantly and nothing can be edited) and when the context has no listing.
    ///
    /// The token the caret is completing is left out: the keyboard bar already offers it, and the
    /// row calling it a typo or a mention as well would say it twice.
    public static func rowItems(text: String, caret: Int?, names: [String], liveTake: Bool) -> [RowItem] {
        guard !liveTake, !names.isEmpty, text.contains("/") else { return [] }
        let completing = caret.flatMap { SkillMentions.completion(in: text, caret: $0, names: names)?.range.location }
        return SkillMentions.find(in: text, names: names)
            .filter { $0.range.location != completing }
            .map { RowItem(kind: $0.kind, token: $0.token, name: $0.name) }
    }

    /// The text with the near-miss token corrected, or `nil` when the text no longer holds it.
    /// Looked up again in the current text, so a tap after further typing never edits a stale range.
    public static func fixing(_ item: RowItem, in text: String, names: [String]) -> String? {
        guard
            let mention = SkillMentions.find(in: text, names: names).first(where: {
                $0.kind == .nearMiss && $0.token == item.token
            })
        else { return nil }
        return SkillMentions.replace(mention.range, in: text, with: mention.name).text
    }

    /// The completions for the caret, from user edits only: none for a selection, while the
    /// keyboard holds marked text (dictation, composition), or during a live take.
    public static func completion(
        text: String, selection: NSRange, names: [String], hasMarkedText: Bool, liveTake: Bool
    ) -> SkillMentions.Completion? {
        guard !liveTake, !hasMarkedText, selection.length == 0, !names.isEmpty else { return nil }
        return SkillMentions.completion(in: text, caret: selection.location, names: names)
    }

    /// One edit that completes a token, shaped for `UITextView.replace(_:withText:)` so undo and
    /// the text binding see an ordinary edit.
    public struct Insertion: Equatable, Sendable {
        public let range: NSRange
        public let replacement: String
        /// Where the caret goes in the edited text.
        public let caret: Int
    }

    public static func insertion(replacing range: NSRange, with name: String, in text: String) -> Insertion {
        let edited = SkillMentions.replace(range, in: text, with: name)
        let delta = (edited.text as NSString).length - (text as NSString).length
        let replacement = (edited.text as NSString).substring(
            with: NSRange(location: range.location, length: range.length + delta))
        return Insertion(range: range, replacement: replacement, caret: edited.caret)
    }
}
