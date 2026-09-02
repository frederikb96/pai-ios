import PAIKit
import SwiftUI
import UIKit

/// A note's name, shown as the navigation bar's `.principal` item so it can be tapped and edited
/// in place.
///
/// A `UITextField` wrapper rather than a plain SwiftUI `TextField`: a freshly created note has to
/// open with its placeholder name fully selected, so typing replaces it, and that needs
/// `UITextField.selectAll(_:)` — SwiftUI's own field has no reliable way to ask for the same
/// thing on the exact frame it becomes first responder.
struct NoteTitleField: UIViewRepresentable {
    let text: String
    let isFocused: Bool
    /// True while `text` collides with another note's name — see ``NoteNaming/collides``.
    /// Painted the same red the rest of the app uses for an invalid field; purely a preview, so
    /// it never blocks committing — the server is still the one that decides.
    let isInvalid: Bool
    /// Selects the whole field the moment it becomes first responder — for a freshly created
    /// note, whose placeholder name should be replaced by typing, not appended to.
    let selectsAllOnFocus: Bool
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
        field.textAlignment = .center
        field.returnKeyType = .done
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.adjustsFontForContentSizeCategory = true
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.textColor = UIColor(isInvalid ? PaiPalette.Semantic.errorText : PaiPalette.Semantic.textPrimary)

        if isFocused {
            if !field.isFirstResponder {
                field.becomeFirstResponder()
                if selectsAllOnFocus {
                    // Deferred: `becomeFirstResponder()` has not finished installing a selection
                    // yet on the same run loop turn it is called from.
                    DispatchQueue.main.async { field.selectAll(nil) }
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
