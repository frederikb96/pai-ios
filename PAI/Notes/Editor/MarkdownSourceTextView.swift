import PAIKit
import SwiftUI
import UIKit

/// A caret move the editor is asking for, as opposed to one the reader made.
///
/// Carries a token because a request has to be applied exactly once. Applied whenever it is
/// present, it would be reapplied on every unrelated redraw — a save finishing, a badge changing —
/// and yank the caret back to where it last was set, minutes after the reader moved it somewhere
/// else.
struct CaretRequest: Equatable {
    let token: Int
    /// A UTF-16 offset into the note's whole source.
    let offset: Int
    /// Whether this is an arrival rather than a keystroke's own caret move — an outline heading, a
    /// search hit — and so should settle a third of the way down the page instead of scrolling by
    /// the minimum. See ``MarkdownSourceTextView/Coordinator/scrollCaretIntoView(_:settlingAtTopThird:)``.
    var settlesAtTopThird: Bool = false
}

/// The note's whole markdown source, in one wrapping, editable text view.
///
/// Fenced code and tables lay out inside this same view rather than in their own non-wrapping,
/// sideways-scrolling region — nobody needs a raw `| a | b |` source line to scroll sideways to be
/// readable, and the *rendered* table's own unwrapped grid is preview's job, a completely separate
/// renderer. One text view for the whole note is also what makes an ordinary paragraph break,
/// Backspace and Undo simply UIKit's own behaviour, with no seam anywhere for this editor to get
/// wrong.
struct MarkdownSourceTextView: UIViewRepresentable {

    let text: String
    let isFocused: Bool
    /// Where the editor wants the caret, when something outside the text view asked to jump there.
    /// Nil means leave the caret alone, which is every ordinary keystroke.
    let caret: CaretRequest?
    /// What the in-note search is looking for. Every occurrence stays painted while it is set,
    /// which is what makes "find in note" usable without leaving the editor.
    let highlight: String?

    let onChange: (String) -> Void
    let onFocus: () -> Void
    /// The keyboard bar's paperclip, carrying the caret's UTF-16 offset — where whatever is picked
    /// has to end up. Captured at the tap because presenting a picker takes the keyboard away, and
    /// with it the selection.
    let onAttach: (Int) -> Void

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1, explicitly. The editor repaints after every keystroke, and the only way to do
        // that without destroying the undo stack is to change attributes on the text storage in
        // place — reassigning `attributedText` replaces the whole string, which UIKit records as
        // one wholesale edit and which drops the selection. `textStorage` is TextKit 1's API, and
        // merely touching it on a TextKit 2 view silently falls back anyway; asking for it up
        // front makes that a decision rather than a side effect.
        let view = UITextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.tintColor = NoteEditorTheme.accent
        view.inputAccessoryView = context.coordinator.keyboardBar
        view.autocorrectionType = .yes
        view.autocapitalizationType = .sentences
        view.spellCheckingType = .default
        // Markdown is punctuation. Smart quotes and dashes would rewrite `--force` and `"a"` as
        // they are typed, which is the same corruption the transcript parser disables smart
        // punctuation to avoid — and here it would be written back to the vault.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        // The page's own ScrollView scrolls; this view only ever grows to fit its content.
        view.isScrollEnabled = false
        view.textContainer.widthTracksTextView = true

        view.attributedText = NoteEditorTheme.attributedText(for: text, highlight: highlight)
        context.coordinator.paintedHighlight = highlight
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self

        // Only when it actually differs. Assigning `attributedText` resets the selection, so
        // doing it on every update would drag the caret to the end on every keystroke — the
        // single most obvious way an editor feels broken.
        if view.text != text {
            let selected = view.selectedRange
            view.attributedText = NoteEditorTheme.attributedText(for: text, highlight: highlight)
            view.selectedRange = NSRange(
                location: min(selected.location, view.text.utf16.count), length: 0)
            context.coordinator.paintedHighlight = highlight
        } else if context.coordinator.paintedHighlight != highlight {
            // The text is unchanged and only what is being searched for moved, so the string must
            // not be reassigned — restyling the storage in place leaves the caret and the undo
            // stack alone.
            NoteEditorTheme.repaint(view.textStorage, highlight: highlight)
            context.coordinator.paintedHighlight = highlight
        }

        // `isFocused` drives first-responder status in both directions, not only upwards: a
        // sheet covering this view (see `NoteEditorSurface/isCoveredBySheet`) makes it false
        // regardless of whether the reader was mid-keystroke, and this is what actually lets go
        // of the keyboard rather than merely skipping the next reclaim — a view that already is
        // first responder stays one under an `if isFocused` with no `else`, sheet or not.
        if isFocused {
            if !view.isFirstResponder { view.becomeFirstResponder() }
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }

        if let caret, caret.token != context.coordinator.appliedCaretToken {
            context.coordinator.appliedCaretToken = caret.token
            let clamped = min(max(caret.offset, 0), view.text.utf16.count)
            view.selectedRange = NSRange(location: clamped, length: 0)
            context.coordinator.scrollCaretIntoView(view, settlingAtTopThird: caret.settlesAtTopThird)
        }
    }

    /// The view reports its own full height, and the page's `ScrollView` scrolls around it — it
    /// never scrolls itself.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        // A proposal with no width happens only while the parent is still deciding; the view's own
        // current width is the best answer available and settles on the next pass. Reaching for
        // the screen instead would be wrong on iPad and is deprecated besides.
        let width = proposal.width ?? uiView.bounds.width
        return CGSize(
            width: width,
            height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
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
            showsFormatting: !MarkdownFenceState.isInsideFence(text: parent.text, caretUtf16: 0)
        ) { [weak self] item in
            self?.handle(item)
        }

        /// The text view this coordinator drives, set on the first delegate callback. The bar's
        /// actions arrive from UIKit with no view attached to them.
        private weak var textView: UITextView?

        /// The repaint after a keystroke re-scans the *whole* note on every call — cheap for a
        /// short note and expensive for a large one, scaling close to linearly with note length.
        /// Debouncing collapses a fast typing burst into one pass instead of one per character;
        /// see ``scheduleRepaint(_:)``.
        private var repaintWorkItem: DispatchWorkItem?
        private static let repaintDebounce: TimeInterval = 0.12

        init(parent: MarkdownSourceTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            self.textView = textView
            let source = textView.text ?? ""
            scheduleRepaint(textView)
            parent.onChange(source)
        }

        /// Coalesces the highlighter pass onto a short idle gap instead of running it after every
        /// character. The text itself is never held up — UIKit already painted the raw keystroke
        /// before this delegate callback runs; only the *styling* catches up a beat later.
        private func scheduleRepaint(_ textView: UITextView) {
            repaintWorkItem?.cancel()
            let highlight = parent.highlight
            let work = DispatchWorkItem { [weak textView] in
                guard let textView, textView.window != nil else { return }
                NoteEditorTheme.repaint(textView.textStorage, highlight: highlight)
            }
            repaintWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.repaintDebounce, execute: work)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            self.textView = textView
            parent.onFocus()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            self.textView = textView
            let insideFence = MarkdownFenceState.isInsideFence(
                text: textView.text ?? "", caretUtf16: textView.selectedRange.location)
            keyboardBar.setShowsFormatting(!insideFence)
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
            guard text == "\n" else { return true }
            let source = textView.text ?? ""
            guard !MarkdownFenceState.isInsideFence(text: source, caretUtf16: range.location) else { return true }
            guard
                let continuation = MarkdownListContinuation.onReturn(text: source, caretUtf16: range.location)
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
            case .undo:
                textView.undoManager?.undo()
            case .redo:
                textView.undoManager?.redo()
            case .command(let command):
                let source = textView.text ?? ""
                guard !MarkdownFenceState.isInsideFence(text: source, caretUtf16: textView.selectedRange.location)
                else { return }
                guard let edit = MarkdownEditing.edit(command, in: source, selection: textView.selectedRange)
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
        /// This view does not scroll — it reports its full height and the page scrolls around it —
        /// so UIKit's own "keep the insertion point visible" does nothing here: it belongs to a
        /// scrolling text view, and this one deliberately is not. Without this, typing near the
        /// bottom of a long note puts the caret under the keyboard and leaves it there.
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
