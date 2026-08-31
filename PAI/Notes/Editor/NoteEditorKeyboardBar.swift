import PAIKit
import UIKit

/// What a tap on the editor's keyboard bar is asking for.
enum NoteEditorBarItem: Equatable {
    case command(MarkdownCommand)
    case undo
    case redo
    /// Put a photo or a file into the note, at the caret.
    case attach
    case dismissKeyboard
}

/// The row of controls above the keyboard while a note is being edited.
///
/// A phone keyboard covers the toolbar at the top of the screen, so every formatting control the
/// editor offers has to live here or be unreachable while typing. The formatting half scrolls,
/// because the list is longer than a phone is wide and dropping items to make it fit would mean
/// choosing which markdown someone is not allowed to write with their thumbs. The way down out of
/// the keyboard is pinned instead — it is the one control that must never require a scroll to
/// find, and the composer's own bar puts it in the same place for the same reason.
final class NoteEditorKeyboardBar: UIView {

    private let onItem: (NoteEditorBarItem) -> Void

    /// In tap order rather than in markdown order: what gets used most, first. Outdent/indent sit
    /// next to the list buttons, matching the web editor's own toolbar order.
    private static let commands: [(MarkdownCommand, String, String)] = [
        (.heading, "textformat.size", "Heading"),
        (.bold, "bold", "Bold"),
        (.italic, "italic", "Italic"),
        (.bulletList, "list.bullet", "Bulleted list"),
        (.checkbox, "checklist", "Checklist item"),
        (.outdent, "decrease.indent", "Outdent"),
        (.indent, "increase.indent", "Indent"),
        (.inlineCode, "chevron.left.forwardslash.chevron.right", "Code"),
        (.quote, "text.quote", "Quote"),
        (.link, "link", "Link"),
    ]

    /// The formatting buttons, hidden as a group while the caret is inside a fenced code block —
    /// see ``setShowsFormatting(_:)``. Built with a default value here rather than left `nil` so
    /// the `let stack` below can reference it before `super.init()` returns.
    private let formattingStack = UIStackView()

    init(showsFormatting: Bool, onItem: @escaping (NoteEditorBarItem) -> Void) {
        self.onItem = onItem
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        autoresizingMask = .flexibleWidth
        backgroundColor = .secondarySystemBackground

        for (command, symbol, label) in Self.commands {
            formattingStack.addArrangedSubview(button(symbol: symbol, label: label, item: .command(command)))
        }
        formattingStack.axis = .horizontal
        formattingStack.spacing = 2
        formattingStack.isHidden = !showsFormatting

        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        scroller.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            button(symbol: "arrow.uturn.backward", label: "Undo", item: .undo),
            button(symbol: "arrow.uturn.forward", label: "Redo", item: .redo),
            formattingStack,
            button(symbol: "paperclip", label: "Attach a photo or file", item: .attach),
        ])
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(stack)

        let dismiss = button(
            symbol: "keyboard.chevron.compact.down", label: "Hide keyboard", item: .dismissKeyboard)
        dismiss.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroller)
        addSubview(dismiss)

        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroller.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -4),

            stack.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),

            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Whether the caret is inside a fenced code block, where the formatting buttons would splice
    /// markdown into code rather than markup — see ``MarkdownFenceState``. Toggles the whole group
    /// rather than rebuilding it, so moving the caret in and out of a fence never flickers.
    func setShowsFormatting(_ shows: Bool) {
        guard formattingStack.isHidden == shows else { return }
        formattingStack.isHidden = !shows
    }

    private func button(symbol: String, label: String, item: NoteEditorBarItem) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        button.addAction(UIAction { [onItem] _ in onItem(item) }, for: .touchUpInside)
        return button
    }
}
