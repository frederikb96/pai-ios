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

    /// Style whole lines of a note in place, leaving its characters — and so the caret, the
    /// selection and the undo stack — untouched.
    ///
    /// `range` must cover whole lines: everything in it is reset to the body style first, and
    /// only the lines it overlaps are painted back. `text` is `attributed`'s own characters,
    /// handed in so a live text storage is read through its `mutableString` rather than copied.
    ///
    /// `showsHangingIndent` gates the one pass that is not always-on — the gutter and the wrap
    /// indent are one visual feature behind one settings toggle.
    static func paint(
        _ attributed: NSMutableAttributedString, in range: NSRange, index: MarkdownDocumentIndex, text: NSString,
        showsHangingIndent: Bool
    ) {
        // Set, not add: the previous pass's attributes have to go, or a character that stops being
        // bold stays bold forever.
        attributed.setAttributes(baseAttributes(), range: range)

        // A wrapped list item's continuation lines align under the item's own text rather than
        // restarting at the margin — Obsidian's own behaviour, and native TextKit's own way to
        // get it: `headIndent` is resolved during layout using the real, proportional font
        // metrics, so there is no separate pixel-measurement pass to keep in step with the font.
        if showsHangingIndent {
            for indent in index.hangingIndents(overlapping: range, in: text) {
                // The real marker text, not a placeholder — a run of digits and a run of spaces
                // are not the same width in a proportional font, and neither is a tab.
                let marker = text.substring(
                    with: NSRange(location: indent.location, length: indent.markerWidth))
                let style = NSMutableParagraphStyle()
                style.headIndent = (marker as NSString).size(withAttributes: [.font: bodyFont]).width
                attributed.addAttribute(
                    .paragraphStyle, value: style, range: NSRange(location: indent.location, length: indent.length))
            }
        }

        // Block styles come first and inline styles second, in the order the scanner emitted
        // them, so bold inside a heading lands on top of the heading rather than replacing it.
        for span in index.spans(overlapping: range, in: text) {
            apply(span.style, to: attributed, range: NSRange(location: span.location, length: span.length))
        }
    }

    /// What unstyled text carries, and what a keystroke in an empty note types with.
    static func baseAttributes() -> [NSAttributedString.Key: Any] { [.font: bodyFont, .foregroundColor: text] }

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
            // Monospace and a tinted background so a code block still reads as one at a glance
            // even though it wraps like everything else now, rather than scrolling sideways in
            // its own box.
            attributed.addAttributes(
                [.font: codeFont, .foregroundColor: text, .backgroundColor: codeBackground], range: range)
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
