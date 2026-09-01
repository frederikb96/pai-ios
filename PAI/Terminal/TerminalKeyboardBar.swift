import PAIKit
import UIKit

/// What a tap on the terminal's keyboard bar is asking for.
enum TerminalBarItem: Equatable {
    case arrow(TerminalArrowDirection)
    case escape
    /// Arms or disarms sending the next typed letter as a control chord — the coordinator owns
    /// the actual arm/disarm decision, this only reports the tap.
    case controlToggle
    /// A real, submitting Enter — as opposed to the soft keyboard's own Return, which the
    /// coordinator intercepts separately to insert a line break in the pane's prompt instead.
    case enter
}

/// The row of controls above the keyboard while the terminal's input field is focused — the keys
/// a phone has no hardware equivalent for (arrows, Escape, Control) plus a dedicated submit.
///
/// Shaped like `NoteEditorKeyboardBar`: a scrolling row of buttons with one control pinned
/// outside the scroller. Here that pinned control is Enter rather than dismiss-keyboard, since
/// submitting has to always be reachable without a scroll — dismissing the keyboard is already
/// one tap away, on the pane behind it.
final class TerminalKeyboardBar: UIView {

    private let onItem: (TerminalBarItem) -> Void
    private let controlButton = UIButton(type: .system)
    private var isControlArmed = false

    private static let scrollingItems: [(TerminalBarItem, String, String, String)] = [
        (.arrow(.up), "arrow.up", "Up arrow", "terminal-bar-up"),
        (.arrow(.down), "arrow.down", "Down arrow", "terminal-bar-down"),
        (.arrow(.left), "arrow.left", "Left arrow", "terminal-bar-left"),
        (.arrow(.right), "arrow.right", "Right arrow", "terminal-bar-right"),
        (.escape, "escape", "Escape", "terminal-bar-escape"),
    ]

    init(onItem: @escaping (TerminalBarItem) -> Void) {
        self.onItem = onItem
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        autoresizingMask = .flexibleWidth
        backgroundColor = .secondarySystemBackground

        controlButton.setImage(UIImage(systemName: "control"), for: .normal)
        controlButton.accessibilityLabel = "Control"
        controlButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        controlButton.layer.cornerRadius = 8
        controlButton.accessibilityIdentifier = "terminal-bar-control"
        controlButton.addAction(UIAction { [onItem] _ in onItem(.controlToggle) }, for: .touchUpInside)

        var scrollingButtons = Self.scrollingItems.map { item, symbol, label, identifier in
            button(symbol: symbol, label: label, item: item, identifier: identifier)
        }
        scrollingButtons.append(controlButton)

        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        scroller.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: scrollingButtons)
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(stack)

        let enter = button(symbol: "return", label: "Send", item: .enter, identifier: "terminal-bar-enter")
        enter.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroller)
        addSubview(enter)

        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroller.trailingAnchor.constraint(equalTo: enter.leadingAnchor, constant: -4),

            stack.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),

            enter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            enter.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Redraws to reflect whether the next keyboard letter will be sent as a control chord.
    ///
    /// The coordinator owns the actual arm/disarm decision — a chord sent, a non-letter typed
    /// while armed, or this button tapped again — this only ever mirrors it, the same split
    /// `NoteEditorKeyboardBar.setShowsFormatting(_:)` makes between owning a decision and
    /// drawing its result.
    func setControlArmed(_ armed: Bool) {
        guard isControlArmed != armed else { return }
        isControlArmed = armed
        controlButton.backgroundColor = armed ? .tintColor.withAlphaComponent(0.2) : .clear
        controlButton.accessibilityTraits = armed ? [.button, .selected] : .button
    }

    private func button(symbol: String, label: String, item: TerminalBarItem, identifier: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        button.addAction(UIAction { [onItem] _ in onItem(item) }, for: .touchUpInside)
        return button
    }
}
