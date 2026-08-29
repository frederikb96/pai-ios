import SwiftUI
import UIKit

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

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = Self.font
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.text = text
        textView.accessibilityLabel = "Message composer"
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
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

        init(_ parent: ComposerTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
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
