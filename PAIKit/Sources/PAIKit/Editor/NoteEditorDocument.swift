import Foundation

/// A note as the editor holds it: the segments on screen, and the rules for editing across their
/// boundaries.
///
/// The boundaries are the only part of this that is hard. Inside a segment, editing is a text
/// view's own job — typing, selection, paragraph breaks, list continuation, undo, all of it comes
/// from UIKit for nothing. What UIKit cannot know is what should happen when the caret is at the
/// very start of one region and Backspace is pressed, or when typing turns a paragraph into a
/// code block. That is what this type owns, and it owns it as values so it can be tested rather
/// than demonstrated on a phone.
///
/// Segments carry identity separately from content, because SwiftUI has to be able to tell "the
/// same region, edited" from "a different region" — rebuilding a text view mid-keystroke moves
/// the caret to the end, which is the single most obvious way an editor feels broken.
public struct NoteEditorDocument: Equatable, Sendable {

    /// One segment plus the identity the view layer keys on.
    public struct Item: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var segment: NoteSegment

        public init(id: UUID = UUID(), segment: NoteSegment) {
            self.id = id
            self.segment = segment
        }

        public var displayText: String { segment.displayText }
        public var kind: NoteSegmentKind { segment.kind }
    }

    public private(set) var items: [Item]

    /// Where the caret should be put after an edit that moved it — a merge, or a re-split that
    /// dissolved the segment being typed in. `nil` means leave the caret where the text view
    /// already has it, which is the common case and the one that must not be disturbed.
    public struct CaretTarget: Equatable, Sendable {
        public let itemID: UUID
        /// A UTF-16 offset into that item's display text, matching what a text view's selected
        /// range speaks.
        public let offset: Int

        public init(itemID: UUID, offset: Int) {
            self.itemID = itemID
            self.offset = offset
        }
    }

    public init(source: String) {
        let segments = NoteSegmentation.split(source)
        // A note with nothing in it still needs one place to type. Without this the editor opens
        // on an empty note showing no text view at all, which reads as a failure to load.
        self.items =
            segments.isEmpty ? [Item(segment: NoteSegment(kind: .prose, text: ""))] : segments.map { Item(segment: $0) }
    }

    public init(items: [Item]) {
        self.items = items
    }

    public var source: String { NoteSegmentation.join(items.map(\.segment)) }

    public func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    // MARK: Editing

    /// Apply what a text view now holds for one segment.
    ///
    /// Re-splits the whole note, which is what makes structure follow the text: typing a fence
    /// turns a paragraph into a code block and deleting one turns it back, with no rule for
    /// either. Identity is preserved wherever the text is unchanged, so the region being typed in
    /// keeps its view — the re-split is invisible until it actually changes something.
    ///
    /// Returns where to put the caret when the edit dissolved the segment it was in, and `nil`
    /// when it did not.
    public mutating func edit(id: UUID, displayText: String) -> CaretTarget? {
        guard let index = index(of: id) else { return nil }
        let updated = items[index].segment.withDisplayText(displayText)
        guard updated != items[index].segment else { return nil }

        let resplit = NoteSegmentation.split(
            NoteSegmentation.join(items.enumerated().map { $0.offset == index ? updated : $0.element.segment }))

        // The ordinary case: the split is unchanged in shape and only this segment's text moved.
        // Nothing is rebuilt, so nothing can disturb the caret.
        //
        // The edited segment is compared too, and that comparison is load-bearing: `NoteSegment`
        // is equal on kind as well as text, so typing a fence — which changes the kind and
        // nothing else about the split — is caught here rather than slipping through as a plain
        // text change and leaving prose wearing a code block's identity.
        if resplit.count == items.count, resplit[index] == updated,
            zip(resplit, items).enumerated().allSatisfy({ $0.offset == index || $0.element.0 == $0.element.1.segment })
        {
            items[index].segment = updated
            return nil
        }

        // The structure changed. Re-key, keeping identity for segments whose text survived
        // untouched so their views are not rebuilt, and put the caret at the end of whatever
        // now holds the text that was being typed.
        let rekeyed = reidentify(resplit)
        let caret = Self.caretAfterRestructure(displayText: displayText, in: rekeyed)
        items = rekeyed
        return caret
    }

    /// Backspace at the very start of a segment.
    ///
    /// What it does depends on what the boundary is made of, because the two are not the same
    /// thing to undo:
    ///
    /// - Before a **code block**, the boundary is its fences. Dropping only the blank line above
    ///   would leave the block intact and appear to do nothing, and dropping only the opening
    ///   fence would leave the closing one to open a new block that swallows the rest of the
    ///   note. So the block is unwrapped: both fences go and its contents become prose. That is
    ///   also what the keystroke means — the reader is at the top of a region asking for it not
    ///   to be one.
    /// - Before anything else, the boundary is the blank line, so the blank line goes.
    ///
    /// The caret lands where the join happened, so typing carries on from the same place rather
    /// than from an end nobody asked for.
    ///
    /// Does nothing at the very start of the note — there is nothing to join to, and swallowing
    /// the keystroke is better than deleting a character the reader cannot see.
    public mutating func mergeBackward(from id: UUID) -> CaretTarget? {
        guard let index = index(of: id), index > 0 else { return nil }
        // The join point, measured in the previous segment's own display text before the
        // re-split, because the re-split may fuse the two into one region.
        let joinOffset = items[index - 1].displayText.utf16.count

        var texts = items.map(\.segment.text)
        let segment = items[index].segment
        let body = segment.kind == .codeBlock ? Self.unfenced(segment.displayText) : segment.displayText
        texts[index] = body + segment.trailingSeparator

        let rekeyed = reidentify(NoteSegmentation.split(texts.joined()))
        guard !rekeyed.isEmpty else {
            items = [Item(segment: NoteSegment(kind: .prose, text: ""))]
            return CaretTarget(itemID: items[0].id, offset: 0)
        }
        let landing = rekeyed[min(index - 1, rekeyed.count - 1)]
        items = rekeyed
        return CaretTarget(itemID: landing.id, offset: min(joinOffset, landing.displayText.utf16.count))
    }

    /// A fenced block's contents, fences removed. Both go together — a lone closing fence is an
    /// opening one to the next parse, which would turn the rest of the note into code.
    static func unfenced(_ displayText: String) -> String {
        var lines = NoteSegmentation.splitKeepingTerminators(displayText)
        guard let first = lines.first, let fence = NoteSegmentation.openingFence(in: first) else {
            return displayText
        }
        lines.removeFirst()
        if let last = lines.last, NoteSegmentation.closesFence(last, opener: fence) {
            lines.removeLast()
        }
        return lines.joined()
    }

    /// Where a Character offset into the whole note lands among the regions on screen.
    ///
    /// Characters in, UTF-16 out, and the asymmetry is deliberate rather than sloppy: the outline
    /// and the in-note search both count Characters, because that is what the strings they scan
    /// are indexed by, while a text view's selection is an `NSRange` and speaks UTF-16. Converting
    /// here is the one place the two meet, so nothing else has to know which it holds.
    ///
    /// An offset landing in the blank lines between two regions belongs to the region after them
    /// — those lines are the separator the editor does not draw, and there is nowhere else to put
    /// a caret aimed at them.
    public func locate(characterOffset: Int) -> CaretTarget? {
        guard let first = items.first, let last = items.last else { return nil }
        guard characterOffset > 0 else { return CaretTarget(itemID: first.id, offset: 0) }

        var consumed = 0
        for item in items {
            let length = item.segment.text.count
            guard characterOffset < consumed + length || item.id == last.id else {
                consumed += length
                continue
            }
            let display = item.displayText
            let within = characterOffset - consumed - item.segment.leadingSeparator.count
            let clamped = min(max(within, 0), display.count)
            return CaretTarget(itemID: item.id, offset: String(display.prefix(clamped)).utf16.count)
        }
        return CaretTarget(itemID: last.id, offset: 0)
    }

    /// Give a note that ends in a code block or a table somewhere to type.
    ///
    /// Without this, a note whose last line is a closing fence has no wrapping region at the
    /// bottom at all, and the only way to add a paragraph after the block is to type inside it and
    /// then break out — which for a fenced block means editing the fence. Returns where the caret
    /// goes, or `nil` when the last region already wraps and nothing is needed.
    public mutating func appendTrailingProse() -> CaretTarget? {
        guard let last = items.last, last.segment.isNoWrap else { return nil }
        let current = source
        let appended = current + (current.hasSuffix("\n") ? "\n" : "\n\n")
        let rekeyed = reidentify(NoteSegmentation.split(appended))
        guard let landing = rekeyed.last else { return nil }
        items = rekeyed
        return CaretTarget(itemID: landing.id, offset: 0)
    }

    // MARK: Identity

    /// Give re-split segments ids, reusing an existing one wherever a segment's exact text
    /// survived. Matching on text rather than position is what keeps identity through an edit
    /// that inserts or removes a region above.
    private func reidentify(_ segments: [NoteSegment]) -> [Item] {
        var available: [NoteSegment: [UUID]] = [:]
        for item in items { available[item.segment, default: []].append(item.id) }
        return segments.map { segment in
            if var ids = available[segment], !ids.isEmpty {
                let id = ids.removeFirst()
                available[segment] = ids
                return Item(id: id, segment: segment)
            }
            return Item(segment: segment)
        }
    }

    /// Where the caret goes after the structure changed under it: the end of whichever segment
    /// now contains what was just typed.
    ///
    /// Matching on content rather than position because the edit may have merged two segments,
    /// split one in three, or changed a segment's kind — in every case the text the reader was
    /// typing is still somewhere, and that is where they expect to still be.
    private static func caretAfterRestructure(displayText: String, in items: [Item]) -> CaretTarget? {
        if let exact = items.first(where: { $0.displayText == displayText }) {
            return CaretTarget(itemID: exact.id, offset: displayText.utf16.count)
        }
        if let containing = items.first(where: { $0.displayText.contains(displayText) }),
            let range = containing.displayText.range(of: displayText)
        {
            let offset = containing.displayText.utf16.distance(
                from: containing.displayText.utf16.startIndex,
                to: range.upperBound.samePosition(in: containing.displayText.utf16)
                    ?? containing.displayText.utf16.endIndex
            )
            return CaretTarget(itemID: containing.id, offset: offset)
        }
        guard let last = items.last else { return nil }
        return CaretTarget(itemID: last.id, offset: last.displayText.utf16.count)
    }
}
