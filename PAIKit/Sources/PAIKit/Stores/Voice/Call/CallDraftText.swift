import Foundation

/// The bound session's draft while a call writes its live turn into it: `base` is everything in
/// the draft that is not the turn — text that was there when the call began, and anything typed
/// or pasted since — and the turn's preview is always written after it.
///
/// A send posts the base together with the turn, so the draft on screen is exactly what goes out,
/// and the base is dropped once the send succeeds.
public struct CallDraftText: Sendable, Equatable {
    public private(set) var base: String
    /// The preview as last written — `nil` forces the next preview to be written.
    public private(set) var writtenPreview: String?
    /// The whole draft as last written — a draft that differs from it was changed by something else.
    private var writtenDraft: String?

    public init(base: String) {
        self.base = base
    }

    /// Adopts a change something else made to the draft since the last write. An edit that keeps
    /// the preview at the end, or removes it, becomes the new base. A draft that is an older
    /// state of the last write — the same base with only part of the preview — is a stale echo
    /// and is overwritten, as is any edit inside the preview.
    public mutating func adopt(currentDraft current: String) {
        guard let written = writtenDraft, current != written else { return }
        let previewPart = VoiceRecordingResult.composeLiveText(pre: "", partial: writtenPreview ?? "")
        if !previewPart.isEmpty, written.hasPrefix(current), current.hasPrefix(base) {
            return
        }
        if previewPart.isEmpty || !current.contains(previewPart) {
            base = current
        } else if current.hasSuffix(previewPart) {
            base = String(current.dropLast(previewPart.count)).trimmingCharacters(in: .whitespaces)
        } else {
            return
        }
        writtenPreview = nil
        writtenDraft = nil
    }

    /// The draft to write for `preview`, or `nil` when the draft already shows it.
    public mutating func draft(forPreview preview: String) -> String? {
        guard preview != writtenPreview else { return nil }
        return write(preview: preview)
    }

    /// Appends `text` to the base in place of the preview showing it — for turn text handed back
    /// rather than sent. Returns the draft to write.
    public mutating func appendReplacingPreview(_ text: String) -> String {
        base = base.isEmpty ? text : "\(base) \(text)"
        return write(preview: "")
    }

    /// The message a send posts for `turnText`: the base first, then the turn.
    public func message(turnText: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return [trimmedBase, turnText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A send carrying `sentBase` went out — that part of the base is gone from the draft. Text
    /// added after it while the send was in flight stays. Returns the draft to write.
    public mutating func baseSent(_ sentBase: String) -> String {
        let sent = sentBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(sent) {
            base = String(trimmed.dropFirst(sent.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return write(preview: writtenPreview ?? "")
    }

    private mutating func write(preview: String) -> String {
        let text = VoiceRecordingResult.composeLiveText(pre: base, partial: preview)
        writtenPreview = preview
        writtenDraft = text
        return text
    }
}
