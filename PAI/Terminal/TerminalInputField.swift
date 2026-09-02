import PAIKit
import SwiftUI
import UIKit

/// A visible field that buffers a draft locally and only reaches the pane on Return or the bar's
/// own Enter — never per keystroke.
///
/// Deliberately visible rather than a hidden keyboard-summoning trick — an invisible field would
/// be cleverer and would leave Freddy with no idea what he has typed. It is not live per-character
/// forwarding: a same-chunk carriage return is what lets the pane tell a line break from a submit
/// apart, and once a character has already gone out on its own there is nothing left for a later,
/// separately-sent carriage return to share a chunk with. So typing and backspacing stay purely
/// local — an ordinary field already does both for free — and the whole draft travels in one
/// request only when Return or the bar's Enter asks for it.
struct TerminalInputField: UIViewRepresentable {
    /// Set from outside to focus or dismiss programmatically; read back through `onFocus` so a
    /// tap directly on the field — which UIKit handles on its own, with no help from this
    /// binding — never disagrees with it. Without that second path, the very next unrelated
    /// state change would see `isFocused` still `false` and forcibly resign a field the reader
    /// just tapped into.
    let isFocused: Bool
    /// An arrow, Escape or a control chord from the bar — sent immediately, bypassing the draft,
    /// since these act on the pane's own state rather than composing a line to submit later.
    let onSendImmediate: (String) -> Void
    /// The soft keyboard's own Return — a line break in the pane's prompt, not a submit. Carries
    /// the field's whole draft, since nothing has reached the pane yet; needs the `literal` flag
    /// on the request, which `TerminalScreen` owns, so the field hands up the text rather than
    /// the byte.
    let onSendLineBreak: (String) -> Void
    /// A real, submitting Enter, sent when the bar's own Enter button is tapped. Also carries the
    /// draft — buffering means a submit with no text would just press Enter on an empty prompt.
    let onSubmit: (String) -> Void
    let onFocus: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.spellCheckingType = .no
        field.placeholder = "Type to send to the pane…"
        field.delegate = context.coordinator
        field.inputAccessoryView = context.coordinator.keyboardBar
        field.accessibilityIdentifier = "terminal-input-field"
        context.coordinator.textField = field
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if isFocused {
            if !field.isFirstResponder { field.becomeFirstResponder() }
        } else if field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TerminalInputField
        /// Read to flush the draft on Return/Enter and to clear the field afterwards — everything
        /// else it does is driven by the delegate callback, which UIKit already hands the field to
        /// as an argument.
        weak var textField: UITextField?

        /// Whether the next typed letter is sent as a control chord rather than inserted —
        /// armed by the bar's Control button, consumed (or dropped) by the very next keystroke.
        /// Owned here rather than by the bar itself, since arming has to survive the bar being
        /// rebuilt and the bar has no other state of its own to carry it in.
        private var controlArmed = false {
            didSet { keyboardBar.setControlArmed(controlArmed) }
        }

        lazy var keyboardBar: TerminalKeyboardBar = TerminalKeyboardBar { [weak self] item in
            self?.handle(item)
        }

        init(parent: TerminalInputField) {
            self.parent = parent
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onFocus()
        }

        /// `UITextField` never routes Return through `shouldChangeCharactersIn` — a single-line
        /// field asks this instead, so the soft keyboard's Return key is intercepted here rather
        /// than as a `"\n"` case below, which would simply never fire.
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSendLineBreak(textField.text ?? "")
            textField.text = ""
            return false
        }

        /// Intercepts only the letter that would complete an armed Control chord — every other
        /// keystroke, including backspace, is left to insert or delete locally with no call out.
        /// The chord letter itself must never land in the field, which is why this stays a
        /// before-insert interception rather than reading the field back after the fact.
        func textField(
            _ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String
        ) -> Bool {
            guard controlArmed else { return true }
            controlArmed = false
            if string.count == 1, let letter = string.first, let chord = TerminalKeyBytes.controlChord(for: letter) {
                parent.onSendImmediate(chord)
                return false
            }
            // Armed but the next key was not a letter (including a plain backspace) — disarm and
            // fall through, so a mistap never stays stuck waiting for a chord that will never come.
            return true
        }

        private func handle(_ item: TerminalBarItem) {
            switch item {
            case .arrow(let direction):
                parent.onSendImmediate(TerminalKeyBytes.arrow(direction))
            case .escape:
                parent.onSendImmediate(TerminalKeyBytes.escape)
            case .controlToggle:
                controlArmed.toggle()
            case .enter:
                let draft = textField?.text ?? ""
                textField?.text = ""
                parent.onSubmit(draft)
            }
        }
    }
}
