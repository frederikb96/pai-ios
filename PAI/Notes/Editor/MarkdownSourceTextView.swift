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

    let onChange: (String) -> Void
    /// Backspace with the caret at the very start. Returning true means the editor handled it by
    /// joining this region to the one above; false lets the text view do its usual nothing.
    let onDeleteBackwardAtStart: () -> Bool
    let onFocus: () -> Void

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
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
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
            view.textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer.lineBreakMode = .byClipping
            view.backgroundColor = NoteEditorTheme.codeBackground
            view.layer.cornerRadius = 6
            view.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        }

        view.attributedText = NoteEditorTheme.attributedText(for: text, kind: kind)
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
            view.attributedText = NoteEditorTheme.attributedText(for: text, kind: kind)
            view.selectedRange = NSRange(
                location: min(selected.location, view.text.utf16.count), length: 0)
        }

        if isFocused, !view.isFirstResponder {
            view.becomeFirstResponder()
        }

        if let caret, caret.token != context.coordinator.appliedCaretToken {
            context.coordinator.appliedCaretToken = caret.token
            let clamped = min(max(caret.offset, 0), view.text.utf16.count)
            view.selectedRange = NSRange(location: clamped, length: 0)
            context.coordinator.scrollCaretIntoView(view)
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

        init(parent: MarkdownSourceTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            let source = textView.text ?? ""
            NoteEditorTheme.repaint(textView.textStorage, kind: parent.kind)
            parent.onChange(source)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocus()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.isFirstResponder else { return }
            scrollCaretIntoView(textView)
        }

        /// Keep the caret on screen inside whatever scroll view the page is built from.
        ///
        /// A wrapping region does not scroll — it reports its full height and the page scrolls
        /// around it — so UIKit's own "keep the insertion point visible" does nothing here: it
        /// belongs to a scrolling text view, and this one deliberately is not. Without this,
        /// typing near the bottom of a long note puts the caret under the keyboard and leaves it
        /// there.
        ///
        /// The enclosing scroll view is found by walking superviews rather than being passed in,
        /// because SwiftUI does not hand one over. Public API throughout, and a page that turns
        /// out not to be built from a `UIScrollView` simply gets nothing rather than misbehaving.
        func scrollCaretIntoView(_ textView: UITextView) {
            guard let selection = textView.selectedTextRange else { return }
            var ancestor = textView.superview
            while let candidate = ancestor, !(candidate is UIScrollView) { ancestor = candidate.superview }
            guard let scrollView = ancestor as? UIScrollView else { return }

            let caret = textView.caretRect(for: selection.end)
            guard !caret.isNull, !caret.isInfinite else { return }
            let inScrollView = scrollView.convert(caret, from: textView)
            // Padded so the caret does not sit flush against the keyboard or the navigation bar,
            // which reads as clipped even when every pixel of it is on screen.
            let padded = inScrollView.insetBy(dx: 0, dy: -24)
            // Deferred: this is reached from `updateUIView`, which runs inside a layout pass, and
            // scrolling from inside one re-enters layout.
            DispatchQueue.main.async {
                guard textView.isFirstResponder else { return }
                scrollView.scrollRectToVisible(padded, animated: false)
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
