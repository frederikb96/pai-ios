import PAIKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The composer's `UITextView`, auto-growing up to a cap then scrolling internally — the web's
/// `<textarea rows={1}>` with a 200px height cap ported to a native measured view rather than a
/// SwiftUI `TextEditor`, which has no way to report its own intrinsic content height back to a
/// parent that needs to lay out a send button beside it.
///
/// Return is always a newline. The web only reaches that rule on a touch pointer
/// (`useMediaQuery('(pointer: coarse)')`, which iPhone always satisfies); since this app has no
/// iPad hardware-keyboard case to weigh against it, Return-as-newline applies unconditionally and
/// the Send button is the only way to send.
struct ComposerTextEditor: UIViewRepresentable {
    static let minHeight: CGFloat = 36
    static let maxHeight: CGFloat = 200

    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    /// Set right before a programmatic write (a voice transcript arriving) and consumed on the
    /// next layout pass — scrolls to the tail instead of leaving the view wherever the caret last
    /// was, mirroring the web's `followTailRef`: incoming transcription text lands past whatever
    /// the caret is sitting at, not at it.
    @Binding var scrollToTailOnNextUpdate: Bool
    /// Called with whatever images a paste carried, in pasteboard order. Staging, compression and
    /// the size limit stay the composer's business, exactly as they are for the photo picker; it
    /// answers the markers to put at the caret (`PasteMarkers`), or `nil` to attach unmarked.
    var onPasteImages: ([PastedImage]) -> String?
    /// The skills this composer's context offers. Empty offers no completions.
    var skillNames: [String] = []
    /// True while a live take owns the text: nothing is suggested, because the take rewrites the
    /// field and the caret is not the reader's.
    var skillSuggestionsPaused = false
    /// The caret as the reader last placed it (`nil` for a selection), so the mentions row can
    /// leave out the token the keyboard bar is completing.
    var onCaretChange: (Int?) -> Void = { _ in }

    func makeUIView(context: Context) -> UITextView {
        let textView = PasteAwareTextView()
        textView.font = Self.font
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.text = text
        textView.accessibilityLabel = "Message composer"
        textView.onPasteImages = { images in onPasteImages(images) }
        textView.inputAccessoryView = context.coordinator.makeKeyboardBar()
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        let suggestionInputsChanged =
            coordinator.skillNames != skillNames || coordinator.suggestionsPaused != skillSuggestionsPaused
        coordinator.skillNames = skillNames
        coordinator.suggestionsPaused = skillSuggestionsPaused
        if uiView.text != text {
            // A programmatic write (a take, a synced draft) is not an edit by the reader, so it
            // offers nothing; the next edit or caret move does.
            coordinator.withProgrammaticWrite { uiView.text = text }
            coordinator.clearSuggestions()
            DispatchQueue.main.async { coordinator.reportCaret(of: uiView) }
        } else if suggestionInputsChanged {
            coordinator.refreshSuggestions(in: uiView)
        }
        (uiView as? PasteAwareTextView)?.onPasteImages = { images in onPasteImages(images) }
        context.coordinator.applyPlaceholder(to: uiView, placeholder: placeholder, isEmpty: text.isEmpty)
        recalculateHeight(uiView)
        if scrollToTailOnNextUpdate {
            DispatchQueue.main.async {
                let bottom = NSRange(location: (uiView.text as NSString).length, length: 0)
                uiView.scrollRangeToVisible(bottom)
                scrollToTailOnNextUpdate = false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func recalculateHeight(_ uiView: UITextView) {
        let size = uiView.sizeThatFits(CGSize(width: uiView.bounds.width, height: .greatestFiniteMagnitude))
        let clamped = min(max(size.height, Self.minHeight), Self.maxHeight)
        if abs(clamped - height) > 0.5 {
            DispatchQueue.main.async { height = clamped }
        }
    }

    private static var font: UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: ComposerTextEditor
        private var placeholderLabel: UILabel?

        var skillNames: [String] = []
        var suggestionsPaused = false
        private var isWritingProgrammatically = false
        private var keyboardBar: UIToolbar?
        private var dismissItem: UIBarButtonItem?
        private var shownCandidates: [String] = []

        init(_ parent: ComposerTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            refreshSuggestions(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isWritingProgrammatically else { return }
            reportCaret(of: textView)
            refreshSuggestions(in: textView)
        }

        func reportCaret(of textView: UITextView) {
            let selection = textView.selectedRange
            parent.onCaretChange(selection.length == 0 ? selection.location : nil)
        }

        func withProgrammaticWrite(_ write: () -> Void) {
            isWritingProgrammatically = true
            write()
            isWritingProgrammatically = false
        }

        // MARK: Skill completions

        /// Recomputes the completions for the caret. Called only for edits and caret moves the
        /// reader made; `SkillComposer.completion` decides when to stay silent (marked text, a
        /// selection, a live take).
        func refreshSuggestions(in textView: UITextView) {
            guard !skillNames.isEmpty else { return clearSuggestions() }
            let completion = SkillComposer.completion(
                text: textView.text, selection: textView.selectedRange, names: skillNames,
                hasMarkedText: textView.markedTextRange != nil, liveTake: suggestionsPaused)
            show(completion?.candidates ?? [], in: textView)
        }

        func clearSuggestions() {
            show([], in: nil)
        }

        private func show(_ candidates: [String], in textView: UITextView?) {
            guard candidates != shownCandidates, let keyboardBar, let dismissItem else { return }
            shownCandidates = candidates
            let room = max(0, (keyboardBar.bounds.width > 0 ? keyboardBar.bounds.width : 320) - 72)
            let font = UIFont.systemFont(ofSize: 15)
            var used: CGFloat = 0
            var chips: [UIBarButtonItem] = []
            for name in candidates {
                let width = (("/" + name) as NSString).size(withAttributes: [.font: font]).width + 24
                if !chips.isEmpty, used + width > room { break }
                used += width
                let action = UIAction(title: "/" + name) { [weak self, weak textView] _ in
                    guard let self, let textView else { return }
                    self.complete(with: name, in: textView)
                }
                chips.append(UIBarButtonItem(primaryAction: action))
            }
            keyboardBar.setItems(chips + [UIBarButtonItem(systemItem: .flexibleSpace), dismissItem], animated: false)
        }

        /// Replaces the partial token at the caret through the text view's own edit path, so undo
        /// and the delegate see an ordinary edit.
        private func complete(with name: String, in textView: UITextView) {
            guard
                let completion = SkillComposer.completion(
                    text: textView.text, selection: textView.selectedRange, names: skillNames,
                    hasMarkedText: textView.markedTextRange != nil, liveTake: suggestionsPaused),
                completion.candidates.contains(name)
            else { return clearSuggestions() }
            let insertion = SkillComposer.insertion(replacing: completion.range, with: name, in: textView.text)
            guard
                let start = textView.position(from: textView.beginningOfDocument, offset: insertion.range.location),
                let end = textView.position(from: start, offset: insertion.range.length),
                let range = textView.textRange(from: start, to: end)
            else { return }
            textView.replace(range, withText: insertion.replacement)
            if parent.text != textView.text { parent.text = textView.text }
            if textView.selectedRange != NSRange(location: insertion.caret, length: 0) {
                textView.selectedRange = NSRange(location: insertion.caret, length: 0)
            }
            refreshSuggestions(in: textView)
        }

        /// One explicit way down, always visible while the keyboard is up.
        ///
        /// Tapping the transcript dismisses too, but that only helps someone who thinks to try
        /// it — and on a screen where the keyboard covers most of the conversation there is very
        /// little transcript left to tap. A named control removes the guessing, which is the
        /// same reason browsers put one here.
        func makeKeyboardBar() -> UIToolbar {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
            let dismiss = UIBarButtonItem(
                image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain, target: self,
                action: #selector(dismissKeyboard))
            dismiss.accessibilityLabel = "Hide keyboard"
            bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), dismiss]
            bar.sizeToFit()
            keyboardBar = bar
            dismissItem = dismiss
            return bar
        }

        @objc private func dismissKeyboard() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func applyPlaceholder(to textView: UITextView, placeholder: String, isEmpty: Bool) {
            if placeholderLabel == nil {
                let label = UILabel()
                label.font = ComposerTextEditor.font
                label.textColor = .placeholderText
                label.numberOfLines = 1
                label.translatesAutoresizingMaskIntoConstraints = false
                textView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 4),
                    label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
                ])
                placeholderLabel = label
            }
            placeholderLabel?.text = placeholder
            placeholderLabel?.isHidden = !isEmpty
        }
    }
}

/// One image lifted off the pasteboard, named and typed but not yet staged.
struct PastedImage {
    let data: Data
    let filename: String
    let mimeType: String
}

/// A `UITextView` that treats an image on the pasteboard as an attachment rather than refusing
/// the paste.
///
/// A plain text view offers `Paste` only when the pasteboard holds *text*, so copying a screenshot
/// and long-pressing the composer produces a menu with nothing on it that works — while the web
/// composer in the browser on the same phone has taken a pasted image since it existed
/// (`MessageInput.tsx`'s `handlePaste`). Turning `allowsEditingTextAttributes` on would make the
/// stock paste succeed, but by embedding the picture *in the text* as an attachment character,
/// which is not a file the send path can upload.
final class PasteAwareTextView: UITextView {
    var onPasteImages: (([PastedImage]) -> String?)?

    /// Ordered by preference, not by likelihood: the first type an item actually carries wins, so
    /// a screenshot that offers both PNG and JPEG is taken in the losslessly-encoded one.
    private static let imageTypes: [UTType] = [.png, .jpeg, .heic, .gif, .webP, .tiff]

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let images = Self.pastedImages(from: .general)
        guard !images.isEmpty else {
            super.paste(sender)
            return
        }
        // Text alongside an image is a copy of something that had both — a browser selection,
        // say. That text still belongs in the field; only the picture needs somewhere else to go.
        if UIPasteboard.general.hasStrings {
            super.paste(sender)
        }
        guard let markers = onPasteImages?(images) else { return }
        // The change is handed to the delegate explicitly: the binding behind it is what the draft
        // is, and nothing guarantees `replace` reaches it.
        // Applied as an edit through the text view, not by assigning `text`, so shake-to-undo
        // takes the marker back and the typing before it stays undoable.
        let planned = PasteMarkers.edit(markers, in: text, replacing: selectedRange)
        guard let start = position(from: beginningOfDocument, offset: planned.range.location),
            let end = position(from: start, offset: planned.range.length),
            let range = textRange(from: start, to: end)
        else { return }
        replace(range, withText: planned.replacement)
        selectedRange = NSRange(location: planned.caret, length: 0)
        delegate?.textViewDidChange?(self)
    }

    /// `pasteboard.images` is deliberately not the primary route: it hands back decoded
    /// `UIImage`s, so taking it would mean re-encoding every paste and shipping bytes that are
    /// not the ones that were copied. It stays as the fallback for an item whose type is none of
    /// the ones listed above.
    static func pastedImages(from pasteboard: UIPasteboard) -> [PastedImage] {
        var result: [PastedImage] = []
        for (index, item) in pasteboard.items.enumerated() {
            if let typed = imageTypes.lazy.compactMap({ type -> PastedImage? in
                guard let data = item[type.identifier] as? Data else { return nil }
                let ext = type.preferredFilenameExtension ?? "img"
                return PastedImage(
                    data: data, filename: "pasted-image-\(index + 1).\(ext)",
                    mimeType: type.preferredMIMEType ?? "application/octet-stream")
            }).first {
                result.append(typed)
                continue
            }
            if let image = item.values.compactMap({ $0 as? UIImage }).first,
                let data = image.pngData()
            {
                result.append(
                    PastedImage(data: data, filename: "pasted-image-\(index + 1).png", mimeType: "image/png"))
            }
        }
        return result
    }
}
