import PAIKit
import SwiftUI
import UIKit

/// How a ``MarkdownSourceStyle`` is painted.
///
/// The Obsidian look is made of two decisions, and both are here rather than in the scanner: the
/// markup stays visible but recedes, and the content it describes takes the shape it will have.
/// A `#` is grey and still on screen; the words after it are already heading-sized.
enum NoteEditorTheme {

    /// The editor's base size. Sixteen points, matching the web's own floor — below that iOS
    /// Safari zooms on focus, and while nothing here runs in Safari, the two editors showing the
    /// same note at visibly different sizes is its own kind of wrong.
    static let baseSize: CGFloat = 16

    static var bodyFont: UIFont { .systemFont(ofSize: baseSize) }
    static var codeFont: UIFont { .monospacedSystemFont(ofSize: baseSize - 1, weight: .regular) }

    /// Heading sizes for an *editor*, not for rendered output. The transcript's ramp starts at 30
    /// points, which is right for a heading someone reads and far too large for one they are
    /// typing into on a phone — a line that jumps to 30 points as the space after `#` is typed
    /// reflows everything below it.
    static func headingFont(level: Int) -> UIFont {
        let size: CGFloat =
            switch level {
            case 1: baseSize + 10
            case 2: baseSize + 6
            case 3: baseSize + 3
            default: baseSize + 1
            }
        return .systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
    }

    // MARK: Colours

    /// The palette is SwiftUI `Color`, and attributed-string attributes need `UIColor`. Resolved
    /// through `UIColor(_:)`, which keeps the asset catalog's own light/dark variant intact —
    /// reading a fixed value here instead would freeze the editor in one appearance.
    static var text: UIColor { UIColor(PaiPalette.Notes.text) }
    static var heading: UIColor { UIColor(PaiPalette.Notes.heading) }
    static var muted: UIColor { UIColor(PaiPalette.Notes.muted) }
    static var accent: UIColor { UIColor(PaiPalette.Notes.accent) }
    static var rule: UIColor { UIColor(PaiPalette.Notes.rule) }
    static var codeBackground: UIColor { UIColor(PaiPalette.Notes.codeBackground) }
    static var background: UIColor { UIColor(PaiPalette.Notes.background) }
    /// Behind a "find in note" hit. The transcript's own search colour, so a hit looks the same
    /// wherever it is found.
    static var searchHighlight: UIColor { UIColor(PaiPalette.SearchHighlight.allHits) }

    // MARK: Painting

    /// Build the attributed string a text view shows for one segment of source.
    static func attributedText(for source: String, kind: NoteSegmentKind, highlight: String? = nil)
        -> NSAttributedString
    {
        let attributed = NSMutableAttributedString(string: source)
        paint(attributed, kind: kind, highlight: highlight)
        return attributed
    }

    /// Restyle a live text storage in place, leaving its characters — and so the caret, the
    /// selection and the undo stack — untouched.
    ///
    /// This is what runs on every keystroke. Replacing the string instead would record a
    /// wholesale edit that Undo then reverts as one, which for an editor is worse than no
    /// highlighting at all.
    static func repaint(_ storage: NSTextStorage, kind: NoteSegmentKind, highlight: String? = nil) {
        storage.beginEditing()
        paint(storage, kind: kind, highlight: highlight)
        storage.endEditing()
    }

    private static func paint(
        _ attributed: NSMutableAttributedString, kind: NoteSegmentKind, highlight: String?
    ) {
        let source = attributed.string
        let full = NSRange(location: 0, length: attributed.length)
        // Set, not add: the previous pass's attributes have to go, or a character that stops being
        // bold stays bold forever.
        var base: [NSAttributedString.Key: Any] = [
            .font: kind == .prose ? bodyFont : codeFont, .foregroundColor: text,
        ]
        // A code block and a table scroll sideways, and the paragraph style is what actually
        // decides that: a wide text container stops the *container* forcing a break, but the
        // layout manager still wraps a paragraph whose style asks it to. Clipping instead lays
        // each line out at its full length, which is what there is to scroll.
        if kind != .prose {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            base[.paragraphStyle] = paragraph
        }
        attributed.setAttributes(base, range: full)

        // Block styles come first and inline styles second, in the order the scanner emitted
        // them, so bold inside a heading lands on top of the heading rather than replacing it.
        for span in MarkdownSourceHighlighter.spans(for: source) {
            let range = NSRange(location: span.location, length: span.length)
            guard range.upperBound <= attributed.length else { continue }
            apply(span.style, to: attributed, range: range)
        }

        // Last, so a hit inside inline code is still visibly a hit — that span paints a background
        // of its own, and whichever is applied second is the one that shows.
        guard let highlight, !highlight.isEmpty else { return }
        for range in SearchText.findMatches(in: source, query: highlight)
        where range.upperBound <= attributed.length {
            attributed.addAttribute(.backgroundColor, value: searchHighlight, range: range)
        }
    }

    private static func apply(_ style: MarkdownSourceStyle, to attributed: NSMutableAttributedString, range: NSRange) {
        switch style {
        case .heading(let level):
            attributed.addAttributes(
                [.font: headingFont(level: level), .foregroundColor: heading], range: range)
        case .marker:
            attributed.addAttribute(.foregroundColor, value: muted, range: range)
        case .strong:
            addTrait(.traitBold, to: attributed, range: range)
            attributed.addAttribute(.foregroundColor, value: heading, range: range)
        case .emphasis:
            addTrait(.traitItalic, to: attributed, range: range)
        case .strikethrough:
            attributed.addAttribute(
                .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            attributed.addAttribute(.foregroundColor, value: muted, range: range)
        case .inlineCode:
            attributed.addAttributes(
                [.font: codeFont, .backgroundColor: codeBackground, .foregroundColor: text], range: range)
        case .codeBlockContent:
            attributed.addAttributes([.font: codeFont, .foregroundColor: text], range: range)
        case .linkText, .wikilink:
            attributed.addAttribute(.foregroundColor, value: accent, range: range)
        case .url:
            attributed.addAttributes([.font: codeFont, .foregroundColor: muted], range: range)
        case .quote:
            attributed.addAttribute(.foregroundColor, value: muted, range: range)
            addTrait(.traitItalic, to: attributed, range: range)
        case .listMarker:
            attributed.addAttribute(.foregroundColor, value: accent, range: range)
        case .thematicBreak:
            attributed.addAttribute(.foregroundColor, value: rule, range: range)
        case .frontmatter:
            attributed.addAttributes([.font: codeFont, .foregroundColor: muted], range: range)
        }
    }

    /// Add a trait to whatever font is already on the range, rather than replacing the font.
    ///
    /// Replacing it is the bug this exists to avoid: bold inside a heading would drop back to
    /// body size, and bold inside a code span would stop being monospaced — both of which look
    /// like the highlighter losing track of where it is.
    private static func addTrait(
        _ trait: UIFontDescriptor.SymbolicTraits, to attributed: NSMutableAttributedString, range: NSRange
    ) {
        // Collected first, applied after. Mutating an attributed string from inside its own
        // `enumerateAttribute` is undefined — it can skip ranges or trap, and neither shows up
        // until the string in question is one a real note happens to produce.
        var replacements: [(NSRange, UIFont)] = []
        attributed.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? UIFont else { return }
            let traits = font.fontDescriptor.symbolicTraits.union(trait)
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return }
            replacements.append((subrange, UIFont(descriptor: descriptor, size: font.pointSize)))
        }
        for (subrange, font) in replacements {
            attributed.addAttribute(.font, value: font, range: subrange)
        }
    }
}
