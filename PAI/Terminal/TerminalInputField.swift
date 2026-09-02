import PAIKit
import SwiftUI
import UIKit

/// A visible field that forwards every keystroke to the pane as it is typed, with the terminal
/// action bar as its keyboard accessory.
///
/// Deliberately visible rather than a hidden keyboard-summoning trick — an invisible field would
/// be cleverer and would leave Freddy with no idea where his keystrokes are going. It is not a
/// message composer that holds a whole draft until Send: each character is forwarded the moment
/// it is typed, the same as a real terminal, and what accumulates on screen is a local echo of
/// exactly what has already gone out — not a buffer waiting to be read as one block. It is
/// cleared only when Enter actually submits, since that is the one moment the remote pane's own
/// prompt clears too.
struct TerminalInputField: UIViewRepresentable {
    /// Set from outside to focus or dismiss programmatically; read back through `onFocus` so a
    /// tap directly on the field — which UIKit handles on its own, with no help from this
    /// binding — never disagrees with it. Without that second path, the very next unrelated
    /// state change would see `isFocused` still `false` and forcibly resign a field the reader
    /// just tapped into.
    let isFocused: Bool
    let onSendRaw: (String) -> Void
    /// The soft keyboard's own Return — a line break in the pane's prompt, not a submit. Separate
    /// from `onSendRaw` because it needs the `literal` flag on the request, which `TerminalScreen`
    /// owns; the field itself knows nothing about that route's shape.
    let onSendLineBreak: () -> Void
    /// A real, submitting Enter, sent when the bar's own Enter button is tapped — separate from
    /// `onSendRaw` because pressing it also clears the field, matching a submitted line ending.
    let onSubmit: () -> Void
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
        /// Held only to clear the field on submit — everything else it does is driven by the
        /// delegate callback, which UIKit already hands the field to as an argument.
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
            parent.onSendLineBreak()
            return false
        }

        /// Intercepts every keystroke before it is inserted, rather than inserting and
        /// post-processing — the same shape `MarkdownSourceTextView`'s Return handling and
        /// `NoteEditorKeyboardBar`'s fence check both use, needed here for the Control chord: the
        /// letter that arms it has to never actually land in the field.
        func textField(
            _ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String
        ) -> Bool {
            if string.isEmpty {
                if range.length > 0 {
                    parent.onSendRaw(String(repeating: TerminalKeyBytes.delete, count: range.length))
                }
                return true
            }
            if controlArmed {
                controlArmed = false
                if string.count == 1, let letter = string.first, let chord = TerminalKeyBytes.controlChord(for: letter)
                {
                    parent.onSendRaw(chord)
                    return false
                }
                // Armed but the next key was not a letter — disarm and fall through, so a mistap
                // never stays stuck waiting for a chord that will never come.
            }
            parent.onSendRaw(string)
            return true
        }

        private func handle(_ item: TerminalBarItem) {
            switch item {
            case .arrow(let direction):
                parent.onSendRaw(TerminalKeyBytes.arrow(direction))
            case .escape:
                parent.onSendRaw(TerminalKeyBytes.escape)
            case .controlToggle:
                controlArmed.toggle()
            case .enter:
                // The line just submitted is gone from the pane's own prompt too, so an empty
                // field is what the remote side will actually show next — not a guess, a mirror.
                textField?.text = ""
                parent.onSubmit()
            }
        }
    }
}
