import PAIKit
import SwiftUI
import UIKit

/// A caret move the editor is asking for, as opposed to one the reader made.
///
/// Carries a token because a request has to be applied exactly once. Applied whenever it is
/// present, it would be reapplied on every unrelated redraw — a save finishing, a badge changing —
/// and yank the caret back to where the last restructure left it, minutes after the reader moved
/// it somewhere else.
struct CaretRequest: Equatable {
    let token: Int
    /// A UTF-16 offset into the region's display text.
    let offset: Int
    /// Whether this is an arrival rather than a keystroke's own caret move — an outline heading, a
    /// search hit — and so should settle a third of the way down the page instead of scrolling by
    /// the minimum. See ``MarkdownSourceTextView/Coordinator/scrollCaretIntoView(_:settlingAtTopThird:)``.
    var settlesAtTopThird: Bool = false
}

/// One editable region of a note.
///
/// Two behaviours in one type, chosen by `wraps`, and the difference between them is the whole
/// reason the editor is built from regions at all:
///
/// - **Wrapping** — prose. The view does not scroll; it reports its own height and the page
///   scrolls around it. Text wraps to the width it is given, as text should.
/// - **Not wrapping** — a fenced code block or a table. The text container is unbounded, so every
///   line lays out at full length, and the view scrolls *itself* sideways. That is the thing a
///   single text view cannot do for part of its content: one text container has one wrapping
///   mode, and nothing inside it can be its own scroll region while staying editable.
struct MarkdownSourceTextView: UIViewRepresentable {

    let text: String
    let kind: NoteSegmentKind
    let isFocused: Bool
    /// Where the editor wants the caret, when the document has restructured under it or something
    /// outside the text view asked to jump. Nil means leave the caret alone, which is every
    /// ordinary keystroke.
    let caret: CaretRequest?
    /// What the in-note search is looking for. Every occurrence in this region stays painted while
    /// it is set, which is what makes "find in note" usable without leaving the editor.
    let highlight: String?

    let onChange: (String) -> Void
    /// Backspace with the caret at the very start. Returning true means the editor handled it by
    /// joining this region to the one above; false lets the text view do its usual nothing.
    let onDeleteBackwardAtStart: () -> Bool
    let onFocus: () -> Void
    /// The keyboard bar's paperclip, carrying the caret's UTF-16 offset within this region — where
    /// whatever is picked has to end up. Captured at the tap because presenting a picker takes the
    /// keyboard away, and with it the selection.
    let onAttach: (Int) -> Void

    var wraps: Bool { kind == .prose }

    func makeUIView(context: Context) -> SegmentTextView {
        // TextKit 1, explicitly. The editor repaints on every keystroke, and the only way to do
        // that without destroying the undo stack is to change attributes on the text storage in
        // place — reassigning `attributedText` replaces the whole string, which UIKit records as
        // one wholesale edit and which drops the selection. `textStorage` is TextKit 1's API, and
        // merely touching it on a TextKit 2 view silently falls back anyway; asking for it up
        // front makes that a decision rather than a side effect.
        let view = SegmentTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.onDeleteBackwardAtStart = onDeleteBackwardAtStart
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.tintColor = NoteEditorTheme.accent
        view.inputAccessoryView = context.coordinator.keyboardBar
        // Prose is written to be read, so it gets the keyboard everything else on the phone has —
        // including the predictive bar, which is hidden outright by `.no` and whose absence reads
        // as the app having broken the keyboard. Code and tables keep it off: an identifier is not
        // a word, and a correction applied to one is a bug written into the vault.
        view.autocorrectionType = wraps ? .yes : .no
        view.autocapitalizationType = wraps ? .sentences : .none
        view.spellCheckingType = wraps ? .default : .no
        // Markdown is punctuation. Smart quotes and dashes would rewrite `--force` and `"a"` as
        // they are typed, which is the same corruption the transcript parser disables smart
        // punctuation to avoid — and here it would be written back to the vault.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no

        if wraps {
            view.isScrollEnabled = false
            view.textContainer.widthTracksTextView = true
        } else {
            view.isScrollEnabled = true
            view.alwaysBounceVertical = false
            view.alwaysBounceHorizontal = true
            view.showsVerticalScrollIndicator = false
            view.showsHorizontalScrollIndicator = true
            view.textContainer.widthTracksTextView = false
            // Large and finite. The layout manager does arithmetic on this width, and an
            // infinity-adjacent value in it produces a wrapped line rather than an error.
            view.textContainer.size = CGSize(width: 1_000_000, height: 1_000_000)
            view.textContainer.lineBreakMode = .byClipping
            view.backgroundColor = NoteEditorTheme.codeBackground
            view.layer.cornerRadius = 6
            view.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        }

        view.attributedText = NoteEditorTheme.attributedText(for: text, kind: kind, highlight: highlight)
        context.coordinator.paintedHighlight = highlight
        return view
    }

    func updateUIView(_ view: SegmentTextView, context: Context) {
        context.coordinator.parent = self
        view.onDeleteBackwardAtStart = onDeleteBackwardAtStart

        // Only when it actually differs. Assigning `attributedText` resets the selection, so
        // doing it on every update would drag the caret to the end on every keystroke — the
        // single most obvious way an editor feels broken.
        if view.text != text {
            let selected = view.selectedRange
            view.attributedText = NoteEditorTheme.attributedText(for: text, kind: kind, highlight: highlight)
            view.selectedRange = NSRange(
                location: min(selected.location, view.text.utf16.count), length: 0)
            context.coordinator.paintedHighlight = highlight
        } else if context.coordinator.paintedHighlight != highlight {
            // The text is unchanged and only what is being searched for moved, so the string must
            // not be reassigned — restyling the storage in place leaves the caret and the undo
            // stack alone.
            NoteEditorTheme.repaint(view.textStorage, kind: kind, highlight: highlight)
            context.coordinator.paintedHighlight = highlight
        }

        if isFocused, !view.isFirstResponder {
            view.becomeFirstResponder()
        }

        if let caret, caret.token != context.coordinator.appliedCaretToken {
            context.coordinator.appliedCaretToken = caret.token
            let clamped = min(max(caret.offset, 0), view.text.utf16.count)
            view.selectedRange = NSRange(location: clamped, length: 0)
            context.coordinator.scrollCaretIntoView(view, settlingAtTopThird: caret.settlesAtTopThird)
        }
    }

    /// Height is reported here rather than left to intrinsic sizing, because the two cases need
    /// different answers and only one of them is a question a text view can answer.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SegmentTextView, context: Context) -> CGSize? {
        // A proposal with no width happens only while the parent is still deciding; the view's own
        // current width is the best answer available and settles on the next pass. Reaching for
        // the screen instead would be wrong on iPad and is deprecated besides.
        let width = proposal.width ?? uiView.bounds.width

        guard !wraps else {
            return CGSize(
                width: width,
                height: uiView.sizeThatFits(
                    CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                ).height)
        }

        // A non-wrapping region has exactly one line per newline, so its height is arithmetic
        // rather than a layout question — and asking a scrolling text view for a fitting size
        // gets the proposal back rather than the content's own extent, which would collapse every
        // code block to nothing.
        //
        // Counted from `text` rather than from what the view currently holds: the two differ for
        // the one pass between a change arriving and the view being updated with it, and the
        // symptom of using the stale one is a block whose height lags a frame behind its content.
        // `MarkdownCodeBlockLayout` owns the count so the transcript's code blocks and these
        // cannot disagree about what a line is.
        let lines = MarkdownCodeBlockLayout.lineCount(of: text)
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        return CGSize(
            width: width,
            height: ceil(CGFloat(lines) * NoteEditorTheme.codeFont.lineHeight + insets))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownSourceTextView
        /// The last caret request actually applied — see ``CaretRequest``.
        var appliedCaretToken = Int.min
        /// What the storage was last painted for, so a changed query repaints and an unchanged one
        /// does not.
        var paintedHighlight: String?

        /// Built once and kept, because `inputAccessoryView` is read every time the view becomes
        /// first responder and a fresh bar per focus would flicker as the keyboard comes up.
        lazy var keyboardBar: NoteEditorKeyboardBar = NoteEditorKeyboardBar(
            showsFormatting: parent.kind == .prose
        ) { [weak self] item in
            self?.handle(item)
        }

        /// The text view this coordinator drives, set on the first delegate callback. The bar's
        /// actions arrive from UIKit with no view attached to them.
        private weak var textView: UITextView?

        init(parent: MarkdownSourceTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            self.textView = textView
            let source = textView.text ?? ""
            NoteEditorTheme.repaint(textView.textStorage, kind: parent.kind, highlight: parent.highlight)
            parent.onChange(source)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            self.textView = textView
            parent.onFocus()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            self.textView = textView
            guard textView.isFirstResponder else { return }
            scrollCaretIntoView(textView)
        }

        /// Return inside a list carries the marker down, and the indentation with it.
        ///
        /// Done here rather than after the fact because the newline must not be inserted first:
        /// reacting to it would put the marker on screen one frame late, and undoing it would take
        /// two presses of Undo to get back to where the reader was.
        func textView(
            _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
        ) -> Bool {
            self.textView = textView
            guard text == "\n", parent.kind == .prose else { return true }
            guard
                let continuation = MarkdownListContinuation.onReturn(
                    text: textView.text ?? "", caretUtf16: range.location)
            else { return true }
            let target = NSRange(
                location: range.location - continuation.deleteBefore,
                length: range.length + continuation.deleteBefore)
            guard target.location >= 0 else { return true }
            apply(
                MarkdownEdit(
                    range: target, replacement: continuation.insert,
                    selection: NSRange(
                        location: target.location + continuation.insert.utf16.count, length: 0)),
                to: textView)
            return false
        }

        // MARK: The keyboard bar

        private func handle(_ item: NoteEditorBarItem) {
            guard let textView else { return }
            switch item {
            case .dismissKeyboard:
                textView.resignFirstResponder()
            case .attach:
                parent.onAttach(textView.selectedRange.location)
            case .command(let command):
                guard parent.kind == .prose else { return }
                guard
                    let edit = MarkdownEditing.edit(
                        command, in: textView.text ?? "", selection: textView.selectedRange)
                else { return }
                apply(edit, to: textView)
            }
        }

        /// Put an edit through the text view's own editing path rather than assigning its text.
        ///
        /// Assigning replaces the whole string, which UIKit records as one wholesale change: Undo
        /// after a formatting button would then discard the paragraph rather than the formatting.
        private func apply(_ edit: MarkdownEdit, to textView: UITextView) {
            guard
                let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
                let end = textView.position(from: start, offset: edit.range.length),
                let range = textView.textRange(from: start, to: end)
            else { return }
            textView.replace(range, withText: edit.replacement)
            textView.selectedRange = edit.selection
            // Called explicitly: a programmatic replace not reaching the delegate would leave the
            // note on screen and the note on disk disagreeing, with nothing to notice it. Reaching
            // it twice merely publishes the same text twice.
            textViewDidChange(textView)
        }

        /// Keep the caret on screen inside whatever scroll view the page is built from.
        ///
        /// A wrapping region does not scroll — it reports its full height and the page scrolls
        /// around it — so UIKit's own "keep the insertion point visible" does nothing here: it
        /// belongs to a scrolling text view, and this one deliberately is not. Without this,
        /// typing near the bottom of a long note puts the caret under the keyboard and leaves it
        /// there.
        ///
        /// `settlingAtTopThird` is for an arrival rather than a keystroke — a heading tapped in the
        /// outline, a search hit. Scrolling by the minimum leaves the target flush against the
        /// navigation bar, or already on screen and apparently unmoved; a third of the way down is
        /// where a reader looks for the thing they just asked for.
        ///
        /// The enclosing scroll view is found by walking superviews rather than being passed in,
        /// because SwiftUI does not hand one over. Public API throughout, and a page that turns
        /// out not to be built from a `UIScrollView` simply gets nothing rather than misbehaving.
        func scrollCaretIntoView(_ textView: UITextView, settlingAtTopThird: Bool = false) {
            guard let selection = textView.selectedTextRange else { return }
            var ancestor = textView.superview
            while let candidate = ancestor, !(candidate is UIScrollView) { ancestor = candidate.superview }
            guard let scrollView = ancestor as? UIScrollView else { return }

            let caret = textView.caretRect(for: selection.end)
            guard !caret.isNull, !caret.isInfinite else { return }
            let inScrollView = scrollView.convert(caret, from: textView)
            // Deferred: this is reached from `updateUIView`, which runs inside a layout pass, and
            // scrolling from inside one re-enters layout.
            DispatchQueue.main.async {
                guard textView.isFirstResponder else { return }
                guard settlingAtTopThird else {
                    // Padded so the caret does not sit flush against the keyboard or the navigation
                    // bar, which reads as clipped even when every pixel of it is on screen.
                    scrollView.scrollRectToVisible(inScrollView.insetBy(dx: 0, dy: -24), animated: false)
                    return
                }
                let visible =
                    scrollView.bounds.height - scrollView.adjustedContentInset.top
                    - scrollView.adjustedContentInset.bottom
                let lowest = max(
                    -scrollView.adjustedContentInset.top,
                    scrollView.contentSize.height - visible - scrollView.adjustedContentInset.top)
                let wanted = inScrollView.minY - visible / 3 - scrollView.adjustedContentInset.top
                let clamped = min(
                    max(wanted, -scrollView.adjustedContentInset.top), max(lowest, -scrollView.adjustedContentInset.top)
                )
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: clamped), animated: true)
            }
        }
    }
}

/// A text view that can tell the editor when Backspace was pressed with nothing before the caret.
///
/// A `UITextViewDelegate` cannot answer this: with an empty selection at offset zero there is no
/// text change to propose, so `shouldChangeTextIn` is never called and the keystroke is simply
/// swallowed. Overriding `deleteBackward()` is the only place the press is visible at all.
final class SegmentTextView: UITextView {
    var onDeleteBackwardAtStart: (() -> Bool)?

    override func deleteBackward() {
        if selectedRange.location == 0, selectedRange.length == 0,
            onDeleteBackwardAtStart?() == true
        {
            return
        }
        super.deleteBackward()
    }
}
