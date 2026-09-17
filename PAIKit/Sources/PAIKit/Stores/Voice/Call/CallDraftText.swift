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
    ///
    /// Accepted limitation: a backspace landing exactly at the end, right where the preview was
    /// last written, looks identical to that same stale-echo shape (a shorter draft that is a
    /// prefix of the last write) and is restored rather than kept — the far more common case by
    /// construction, since the preview rewrites the tail on almost every tick, is what this
    /// guards.
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

    /// A send carrying `sentBase` went out — that part of the base is gone from the draft,
    /// wherever it sits: text typed or pasted *before* the sent part while the send was still in
    /// flight is common (the composer stays editable the whole time), not only text added after
    /// it, so a prefix check alone left the sent text stuck in the draft — and resent again on the
    /// next turn — whenever something landed ahead of it. Returns the draft to write.
    public mutating func baseSent(_ sentBase: String) -> String {
        let sent = sentBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sent.isEmpty, let range = trimmed.range(of: sent) {
            let before = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let after = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            base = [before, after].filter { !$0.isEmpty }.joined(separator: " ")
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
