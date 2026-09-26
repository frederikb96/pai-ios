import PAIKit
import SwiftUI
import UIKit

/// A note's name, shown as its own full-width row above the body so nothing — a back button, a
/// toolbar icon — is ever drawn over it, and edited in place.
///
/// A `UITextField` wrapper rather than a plain SwiftUI `TextField`: a freshly created note has to
/// open with the caret already after its placeholder name, so the first keystroke appends rather
/// than replaces, and that needs `UITextField.selectedTextRange` set on the exact frame the field
/// becomes first responder — SwiftUI's own field has no reliable way to ask for the same thing.
/// Left-aligned, single line, never wrapping: unfocused, `UITextField` truncates overflow with an
/// ellipsis on its own; focused, it scrolls horizontally to keep the caret visible — both the
/// system's own default behaviour for a text field wider than its content, needing no code here.
/// "Wider than its content" is the part that does need code, once this stopped being a toolbar
/// item — see `sizeThatFits` below.
struct NoteTitleField: UIViewRepresentable {
    let text: String
    let isFocused: Bool
    /// True while `text` collides with another note's name — see ``NoteNaming/collides``.
    /// Painted the same red the rest of the app uses for an invalid field; purely a preview, so
    /// it never blocks committing — the server is still the one that decides.
    let isInvalid: Bool
    /// Places the caret after the last character, with nothing selected, the moment the field
    /// becomes first responder — for a freshly created note, whose placeholder name should be
    /// appended to by typing, not replaced.
    let placesCaretAtEndOnFocus: Bool
    let onChange: (String) -> Void
    /// Fired the moment the field becomes first responder from an ordinary tap — the field is
    /// always natively tappable, so `isFocused` has to be told about that itself; without it the
    /// next `updateUIView` sees `isFocused == false` while the field is genuinely focused and
    /// immediately resigns it again, which is what a caller reacting to a tap by setting
    /// `isFocused = true` would otherwise be needed for and get wrong on every ordinary tap.
    let onFocus: () -> Void
    /// Fired once editing ends, whichever way it ended — Return, or tapping elsewhere.
    let onCommit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = .preferredFont(forTextStyle: .headline)
        field.textAlignment = .left
        field.returnKeyType = .done
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.adjustsFontForContentSizeCategory = true
        // Compressed rather than allowed to push its own frame wider: as a toolbar item this
        // never mattered, since the bar always imposed a width cap regardless of what the field
        // reported. Moved into an ordinary row, nothing did — a title past a couple of words
        // reported its own full unwrapped width as "ideal", and every ancestor up to the screen's
        // own root widened to fit it, shifting the whole page sideways rather than truncating.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        return field
    }

    /// Reports the width SwiftUI actually offered, never the text's own natural width — the other
    /// half of the fix above. Left to the default `UIViewRepresentable` sizing, this asks the
    /// field's `intrinsicContentSize` regardless of the proposal, which is exactly as wide as an
    /// unwrapped, untruncated rendering of the whole string; a long title then makes this view's
    /// reported "ideal" size wider than the screen, and everything containing it grows to match.
    /// Capping it here is what makes truncation possible at all: a field narrower than its text is
    /// the only shape `UITextField` clips or scrolls instead of overflowing.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        return CGSize(
            width: proposal.width ?? intrinsic.width,
            height: proposal.height ?? intrinsic.height)
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.textColor = UIColor(isInvalid ? PaiPalette.Semantic.errorText : PaiPalette.Semantic.textPrimary)

        if isFocused {
            if !field.isFirstResponder {
                field.becomeFirstResponder()
                if placesCaretAtEndOnFocus {
                    // Deferred: `becomeFirstResponder()` has not finished installing a selection
                    // yet on the same run loop turn it is called from.
                    DispatchQueue.main.async {
                        let end = field.endOfDocument
                        field.selectedTextRange = field.textRange(from: end, to: end)
                    }
                }
            }
        } else if field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NoteTitleField

        init(parent: NoteTitleField) {
            self.parent = parent
        }

        @objc func changed(_ field: UITextField) {
            parent.onChange(field.text ?? "")
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onFocus()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onCommit()
        }
    }
}
