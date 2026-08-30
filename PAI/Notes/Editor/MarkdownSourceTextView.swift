import PAIKit
import SwiftUI
import UIKit

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
    /// A UTF-16 offset to move the caret to, when the document has restructured under it. Nil
    /// means leave the caret alone, which is every ordinary keystroke.
    let caretOffset: Int?

    let onChange: (String) -> Void
    /// Backspace with the caret at the very start. Returning true means the editor handled it by
    /// joining this region to the one above; false lets the text view do its usual nothing.
    let onDeleteBackwardAtStart: () -> Bool
    let onFocus: () -> Void

    var wraps: Bool { kind == .prose }

    func makeUIView(context: Context) -> SegmentTextView {
        let view = SegmentTextView()
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
                width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
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

        if let caretOffset, view.isFirstResponder || isFocused {
            let clamped = min(max(caretOffset, 0), view.text.utf16.count)
            view.selectedRange = NSRange(location: clamped, length: 0)
        }

        if isFocused, !view.isFirstResponder {
            view.becomeFirstResponder()
        }
    }

    /// Height is reported here rather than left to intrinsic sizing, because the two cases need
    /// different answers and only one of them is a question a text view can answer.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SegmentTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width

        guard !wraps else {
            return CGSize(
                width: width,
                height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        }

        // A non-wrapping region has exactly one line per newline, so its height is arithmetic
        // rather than a layout question. Asking the layout system instead would mean reaching for
        // `layoutManager`, and merely touching that property on iOS 16+ silently downgrades the
        // text view from TextKit 2 to TextKit 1 — a change in behaviour with no error and no
        // visible cause.
        let lines = max(1, uiView.text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let lineHeight = NoteEditorTheme.codeFont.lineHeight
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        return CGSize(width: width, height: ceil(CGFloat(lines) * lineHeight + insets))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownSourceTextView

        init(parent: MarkdownSourceTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            let source = textView.text ?? ""
            // Repaint in place. Reassigning `attributedText` would reset the selection, so the
            // caret is captured and restored around it — and it has not moved, because the
            // highlighting changed attributes rather than characters.
            let selected = textView.selectedRange
            textView.attributedText = NoteEditorTheme.attributedText(for: source, kind: parent.kind)
            textView.selectedRange = selected
            parent.onChange(source)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocus()
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
