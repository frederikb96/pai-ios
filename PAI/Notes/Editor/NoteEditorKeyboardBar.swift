import PAIKit
import UIKit

/// What a tap on the editor's keyboard bar is asking for.
enum NoteEditorBarItem: Equatable {
    case command(MarkdownCommand)
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

    /// In tap order rather than in markdown order: what gets used most, first.
    private static let commands: [(MarkdownCommand, String, String)] = [
        (.heading, "textformat.size", "Heading"),
        (.bold, "bold", "Bold"),
        (.italic, "italic", "Italic"),
        (.bulletList, "list.bullet", "Bulleted list"),
        (.checkbox, "checklist", "Checklist item"),
        (.inlineCode, "chevron.left.forwardslash.chevron.right", "Code"),
        (.quote, "text.quote", "Quote"),
        (.link, "link", "Link"),
    ]

    /// `showsFormatting` is false inside a fenced block or a table. The buttons write markdown,
    /// and markdown inside a code block is not markup — tapping Bold there splices `**` into the
    /// code. Attaching a file and getting the keyboard out of the way still apply anywhere.
    init(showsFormatting: Bool, onItem: @escaping (NoteEditorBarItem) -> Void) {
        self.onItem = onItem
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        autoresizingMask = .flexibleWidth
        backgroundColor = .secondarySystemBackground

        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        scroller.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(
            arrangedSubviews: showsFormatting
                ? Self.commands.map { command, symbol, label in
                    button(symbol: symbol, label: label, item: .command(command))
                } : [])
        stack.addArrangedSubview(button(symbol: "paperclip", label: "Attach a photo or file", item: .attach))
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

    private func button(symbol: String, label: String, item: NoteEditorBarItem) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        button.addAction(UIAction { [onItem] _ in onItem(item) }, for: .touchUpInside)
        return button
    }
}
