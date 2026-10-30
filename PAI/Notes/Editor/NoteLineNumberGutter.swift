import PAIKit
import UIKit

/// The line-number gutter beside a note's source — Obsidian's own look: dim numbers, no
/// background band or separator, right-aligned against the text.
///
/// Rides inside the scrolling text view, pinned to the visible area, and draws only the numbers
/// on screen, read off the line fragments TextKit has laid out there. So its cost does not depend
/// on how long the note is. A wrapped line's continuation carries no number of its own.
final class NoteLineNumberGutter: UIView {
    static let width: CGFloat = 32
    /// The space between the numbers and the text they sit beside.
    static let spacing: CGFloat = 6

    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NoteEditorTheme.muted,
    ]

    weak var textView: UITextView?
    /// The number of a line starting at a UTF-16 offset, nil for anywhere else.
    var lineNumber: (Int) -> Int? = { _ in nil }
    /// The number of the empty last line a note ending in a terminator has.
    var lastLineNumber: () -> Int = { 1 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        // A number is chrome describing the text: taps, selection and VoiceOver go past it.
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not built from a storyboard") }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let layoutManager = textView.layoutManager
        let top = textView.textContainerInset.top
        let visible = CGRect(
            x: 0, y: bounds.minY + frame.minY - top, width: textView.bounds.width, height: bounds.height)
        let toScreen = top - frame.minY

        func draw(_ number: Int, at y: CGFloat) {
            let label = String(number) as NSString
            let size = label.size(withAttributes: Self.attributes)
            label.draw(
                at: CGPoint(x: textView.textContainerInset.left - Self.spacing - size.width, y: y + toScreen),
                withAttributes: Self.attributes)
        }

        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textView.textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { [lineNumber] fragment, _, _, range, _ in
            if let number = lineNumber(layoutManager.characterIndexForGlyph(at: range.location)) {
                draw(number, at: fragment.minY)
            }
        }
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty, extra.intersects(visible) { draw(lastLineNumber(), at: extra.minY) }
    }
}
