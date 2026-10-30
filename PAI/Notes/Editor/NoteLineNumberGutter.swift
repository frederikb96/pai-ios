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
            x: 0, y: frame.minY - top, width: textView.bounds.width, height: bounds.height)
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

/// Every occurrence of an in-note search, painted behind the text.
///
/// Pinned over the visible area like the gutter and drawing only the matches inside it, so a
/// thousand hits cost what the few on screen cost. The ranges follow the text as it is edited; a
/// match the edit touched is dropped rather than guessed at.
final class NoteSearchHighlightLayer: UIView {
    weak var textView: UITextView?

    /// Ascending and disjoint, in UTF-16 offsets.
    var matches: [NSRange] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not built from a storyboard") }

    func textChanged(editedRange: NSRange, delta: Int) {
        guard !matches.isEmpty else { return }
        let oldEnd = editedRange.upperBound - delta
        matches = matches.compactMap { match in
            if match.upperBound <= editedRange.location { return match }
            if match.location >= oldEnd { return NSRange(location: match.location + delta, length: match.length) }
            return nil
        }
    }

    override func draw(_ rect: CGRect) {
        guard let textView, !matches.isEmpty else { return }
        let layoutManager = textView.layoutManager
        let origin = CGPoint(
            x: textView.textContainerInset.left - frame.minX, y: textView.textContainerInset.top - frame.minY)
        let visible = CGRect(
            x: 0, y: frame.minY - textView.textContainerInset.top, width: bounds.width, height: bounds.height)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textView.textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        var low = 0
        var high = matches.count
        while low < high {
            let middle = (low + high) / 2
            if matches[middle].upperBound <= characters.location { low = middle + 1 } else { high = middle }
        }
        NoteEditorTheme.searchHighlight.setFill()
        for match in matches[low...] {
            guard match.location < characters.upperBound else { break }
            let matchGlyphs = layoutManager.glyphRange(forCharacterRange: match, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: matchGlyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textView.textContainer
            ) { box, _ in
                UIRectFill(box.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
    }
}
