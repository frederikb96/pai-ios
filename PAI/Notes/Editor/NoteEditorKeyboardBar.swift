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

extension NoteToolbarActionId {
    /// What tapping this action's button in the bar asks for. Exhaustive over every case rather
    /// than a `default`, so a case added to `NoteToolbarActionId` without a matching arm here is a
    /// compile error rather than a button that silently does nothing.
    fileprivate var barItem: NoteEditorBarItem {
        switch self {
        case .undo: return .undo
        case .redo: return .redo
        case .attach: return .attach
        case .heading: return .command(.heading)
        case .bold: return .command(.bold)
        case .italic: return .command(.italic)
        case .bulletList: return .command(.bulletList)
        case .checkbox: return .command(.checkbox)
        case .outdent: return .command(.outdent)
        case .indent: return .command(.indent)
        case .inlineCode: return .command(.inlineCode)
        case .quote: return .command(.quote)
        case .link: return .command(.link)
        }
    }
}

/// The row of controls above the keyboard while a note is being edited.
///
/// A phone keyboard covers the toolbar at the top of the screen, so every formatting control the
/// editor offers has to live here or be unreachable while typing. The bar's own actions —
/// everything but the pinned "hide keyboard" control — come from Settings' formatting-bar layout
/// (spec row 6.5): which of them are enabled, and in what order. It scrolls, because the full
/// action set is longer than a phone is wide. The way down out of the keyboard is pinned instead —
/// it is the one control that must never require a scroll to find, and the composer's own bar puts
/// it in the same place for the same reason. It has no equivalent action id of its own: nothing
/// here configures it away, the same as the web has no toolbar button for it at all.
final class NoteEditorKeyboardBar: UIView {

    private let onItem: (NoteEditorBarItem) -> Void
    private let stack = UIStackView()
    private var currentLayout: [NoteToolbarActionId] = []
    /// The buttons currently in `stack` whose action drives a markdown command — hidden together
    /// while the caret is inside a fenced code block, where tapping one would splice markup into
    /// code rather than markup. Undo, redo and attach stay visible in that state. Rebuilt whenever
    /// `applyLayout` runs, since a layout change replaces every button.
    private var commandButtons: [UIButton] = []
    private var showsFormatting: Bool

    init(layout: [NoteToolbarActionId], showsFormatting: Bool, onItem: @escaping (NoteEditorBarItem) -> Void) {
        self.onItem = onItem
        self.showsFormatting = showsFormatting
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        autoresizingMask = .flexibleWidth
        backgroundColor = .secondarySystemBackground

        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(stack)

        let dismiss = button(symbol: "keyboard.chevron.compact.down", label: "Hide keyboard", item: .dismissKeyboard)
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

        applyLayout(layout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Rebuilds the bar's buttons for a changed enabled/ordered action set. Called whenever
    /// Settings' formatting-bar layout changes, not only once at construction — the row this
    /// exists for requires an already-open editor to reflect a change immediately, and
    /// `inputAccessoryView` is built once and kept for the lifetime of the text view (see
    /// `MarkdownSourceTextView.Coordinator.keyboardBar`'s own doc comment for why).
    func setLayout(_ layout: [NoteToolbarActionId]) {
        guard layout != currentLayout else { return }
        applyLayout(layout)
    }

    private func applyLayout(_ layout: [NoteToolbarActionId]) {
        currentLayout = layout
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var commands: [UIButton] = []
        for id in layout {
            let button = button(symbol: id.symbolName, label: id.label, item: id.barItem)
            stack.addArrangedSubview(button)
            if id.command != nil {
                commands.append(button)
            }
        }
        commandButtons = commands
        applyShowsFormatting()
    }

    /// Whether the caret is inside a fenced code block — see ``MarkdownFenceState``. Toggles the
    /// command buttons as a group rather than rebuilding anything, so moving the caret in and out
    /// of a fence never flickers.
    func setShowsFormatting(_ shows: Bool) {
        guard showsFormatting != shows else { return }
        showsFormatting = shows
        applyShowsFormatting()
    }

    private func applyShowsFormatting() {
        for button in commandButtons {
            button.isHidden = !showsFormatting
        }
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
