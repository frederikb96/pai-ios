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

/// One source line's number and the y-offset, in the text view's own coordinate space, where its
/// first visual row begins — a line-number gutter's only input. A wrapped line contributes
/// several visual rows but only one of these: the gutter draws a number beside the first row of
/// its logical line and nothing beside the rest, matching Obsidian's own gutter.
struct NoteLineMetric: Equatable {
    let lineNumber: Int
    let y: CGFloat
}

/// Every logical line's metric for the current layout, plus the text view's own measured content
/// height — what a gutter, drawn as an ordinary sibling in the page's `ScrollView` rather than a
/// synced overlay, sizes itself to so its numbers land at the same height as the lines beside it.
struct NoteLineMetrics: Equatable {
    static let empty = NoteLineMetrics(lines: [], contentHeight: 0)
    let lines: [NoteLineMetric]
    let contentHeight: CGFloat
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

    /// The top and bottom padding TextKit lays the whole note out inside — one source of truth
    /// for both the text view itself and the line-number gutter drawn beside it, which has to
    /// start its first number at exactly this same offset to land beside the first line.
    static let verticalInset: CGFloat = 6

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
    /// A pasted image, landing wherever the caret was at the moment of the paste — the same
    /// `PastedImage` shape and the same `PasteAwareTextView` the session composer already pastes
    /// images through, reused rather than reimplemented (see that type's own doc comment for why
    /// a plain `UITextView` needs it at all: `Paste` only appears when the pasteboard holds text).
    let onPasteImages: (Int, [PastedImage]) -> Void
    /// Where the line-number gutter is fed from, when it is showing. `nil` while the gutter is
    /// off, which skips the geometry read entirely rather than computing metrics nobody draws —
    /// the cheapest way to guarantee the toggle costs nothing when it is off.
    let onLineMetrics: ((NoteLineMetrics) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1, explicitly. The editor repaints after every keystroke, and the only way to do
        // that without destroying the undo stack is to change attributes on the text storage in
        // place — reassigning `attributedText` replaces the whole string, which UIKit records as
        // one wholesale edit and which drops the selection. `textStorage` is TextKit 1's API, and
        // merely touching it on a TextKit 2 view silently falls back anyway; asking for it up
        // front makes that a decision rather than a side effect.
        let view = PasteAwareTextView(usingTextLayoutManager: false)
        view.onPasteImages = { [weak view] images in
            guard let view else { return }
            context.coordinator.handlePaste(images, at: view.selectedRange.location)
        }
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(
            top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
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
        // Read before `parent` is overwritten below: the gutter toggling on is exactly the
        // moment `onLineMetrics` goes from nil to real, and nothing else about this update would
        // otherwise notice — the text has not changed and the width-gated check further down
        // only fires from a genuine layout pass, which merely flipping the toggle does not cause.
        let justGainedLineMetrics = context.coordinator.parent.onLineMetrics == nil && onLineMetrics != nil
        context.coordinator.parent = self
        if justGainedLineMetrics {
            context.coordinator.reportLineMetricsIfNeeded(view, forcing: true)
        }

        // Only when it actually differs. Assigning `attributedText` resets the selection, so
        // doing it on every update would drag the caret to the end on every keystroke — the
        // single most obvious way an editor feels broken.
        if view.text != text {
            let selected = view.selectedRange
            view.attributedText = NoteEditorTheme.attributedText(for: text, highlight: highlight)
            view.selectedRange = NSRange(
                location: min(selected.location, view.text.utf16.count), length: 0)
            context.coordinator.paintedHighlight = highlight
            // Forced rather than left to the width-gated check below: the text changed here, at
            // whatever width the view already has, so the cached width would wrongly read as
            // "nothing to do" and leave the gutter numbered for the text this view no longer
            // shows — a fresh read, a restored revision, a conflict resolved in the vault's
            // favour, all take this branch and all change what a line number even refers to.
            context.coordinator.reportLineMetricsIfNeeded(view, forcing: true)
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

    /// One metric per logical (source) line, read off layout TextKit has already computed rather
    /// than run as a pass of its own — see this type's own doc comment for why that is cheap
    /// here specifically. A visual row is the first row of its logical line when the glyph range
    /// it covers starts at the very beginning of the document or immediately after a line
    /// terminator; `0x0A`/`0x0D` cover a lone `\n`, a lone old-Mac `\r`, and a `\r\n` pair alike —
    /// TextKit treats `\r\n` as a single terminator, so only the `\n` half of the pair is ever the
    /// character immediately before a real line start.
    static func lineMetrics(for textView: UITextView) -> NoteLineMetrics {
        let layoutManager = textView.layoutManager
        let source = textView.textStorage.string as NSString
        layoutManager.ensureLayout(for: textView.textContainer)

        var lines: [NoteLineMetric] = []
        var lineNumber = 1
        var contentHeight: CGFloat = 0
        let glyphCount = layoutManager.numberOfGlyphs

        guard glyphCount > 0 else {
            return NoteLineMetrics(lines: [NoteLineMetric(lineNumber: 1, y: 0)], contentHeight: 0)
        }

        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: glyphCount)) {
            rect, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let isFirstRowOfLine =
                charIndex == 0 || source.character(at: charIndex - 1) == 0x0A
                || source.character(at: charIndex - 1) == 0x0D
            if isFirstRowOfLine {
                lines.append(NoteLineMetric(lineNumber: lineNumber, y: rect.minY))
                lineNumber += 1
            }
            contentHeight = max(contentHeight, rect.maxY)
        }
        return NoteLineMetrics(lines: lines, contentHeight: contentHeight)
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

        /// The width line metrics were last computed for — see ``reportLineMetricsIfNeeded(_:)``.
        /// `nil` means never: the initial computation and a width change (rotation, a sidebar)
        /// both go through the same guard, and ordinary typing — which changes height, not width
        /// — is deliberately excluded from it, so the gutter never adds a fourth per-keystroke
        /// geometry read on top of the debounced one below.
        private var lastMetricsWidth: CGFloat?

        init(parent: MarkdownSourceTextView) {
            self.parent = parent
        }

        /// Routed through the coordinator rather than captured directly at `makeUIView` time, the
        /// same reason every other callback here goes through `parent` — a closure captured once,
        /// when the view is first created, would keep calling whatever `onPasteImages` this view
        /// was built with, silently missing any prop change since. `parent` is kept current by
        /// `updateUIView`, so reading it here always calls the caller's latest closure.
        func handlePaste(_ images: [PastedImage], at offset: Int) {
            parent.onPasteImages(offset, images)
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
        ///
        /// Line metrics for the gutter piggyback on this same debounce rather than getting a pass
        /// of their own — enumerating the fragments TextKit already laid out for the repaint above
        /// is a cheap geometry read, not a second expensive one.
        private func scheduleRepaint(_ textView: UITextView) {
            repaintWorkItem?.cancel()
            let highlight = parent.highlight
            let onLineMetrics = parent.onLineMetrics
            let work = DispatchWorkItem { [weak textView] in
                guard let textView, textView.window != nil else { return }
                NoteEditorTheme.repaint(textView.textStorage, highlight: highlight)
                if let onLineMetrics {
                    onLineMetrics(MarkdownSourceTextView.lineMetrics(for: textView))
                }
            }
            repaintWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.repaintDebounce, execute: work)
        }

        /// Computes line metrics outside the typing path — the initial layout, and any later
        /// width change (rotation, the sidebar opening). `scrollViewDidLayoutSubviews` fires on
        /// every layout pass, typing included, so the width check is what keeps this from running
        /// on every keystroke: typing changes the text view's height, laid out one dimension at a
        /// time by `sizeThatFits`, but never its width.
        ///
        /// `forcing` bypasses the width cache for a text change at an unchanged width — see the
        /// `updateUIView` call site's own comment for why that path cannot rely on this check.
        /// Either way, a still-zero width (the very first layout pass, before SwiftUI has sized
        /// this view at all) is skipped rather than measured: `ensureLayout` against no width
        /// produces a layout nobody will read, and the next real layout pass reports it correctly
        /// once the cache — left untouched here — still reads as "never computed."
        func reportLineMetricsIfNeeded(_ textView: UITextView, forcing: Bool = false) {
            guard let onLineMetrics = parent.onLineMetrics else { return }
            guard textView.bounds.width > 0 else { return }
            guard forcing || textView.bounds.width != lastMetricsWidth else { return }
            lastMetricsWidth = textView.bounds.width
            onLineMetrics(MarkdownSourceTextView.lineMetrics(for: textView))
        }

        func scrollViewDidLayoutSubviews(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            self.textView = textView
            reportLineMetricsIfNeeded(textView)
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
