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

    /// Build the attributed string a text view shows for the whole note.
    ///
    /// `showsHangingIndent` gates the one pass that is not always-on — the gutter and the
    /// wrap indent are one visual feature behind one settings toggle (spec row 16's own
    /// "BLOCK" framing), so a reader who has not turned the gutter on gets no extra
    /// measurement work either.
    static func attributedText(
        for source: String, highlight: String? = nil, showsHangingIndent: Bool = false
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: source)
        paint(attributed, highlight: highlight, showsHangingIndent: showsHangingIndent)
        return attributed
    }

    /// Restyle a live text storage in place, leaving its characters — and so the caret, the
    /// selection and the undo stack — untouched.
    ///
    /// This is what runs after every keystroke (debounced — see
    /// `MarkdownSourceTextView.Coordinator.scheduleRepaint`). Replacing the string instead would
    /// record a wholesale edit that Undo then reverts as one, which for an editor is worse than
    /// no highlighting at all.
    static func repaint(_ storage: NSTextStorage, highlight: String? = nil, showsHangingIndent: Bool = false) {
        storage.beginEditing()
        paint(storage, highlight: highlight, showsHangingIndent: showsHangingIndent)
        storage.endEditing()
    }

    private static func paint(_ attributed: NSMutableAttributedString, highlight: String?, showsHangingIndent: Bool) {
        let source = attributed.string
        let full = NSRange(location: 0, length: attributed.length)
        // Set, not add: the previous pass's attributes have to go, or a character that stops being
        // bold stays bold forever. The whole note wraps like ordinary prose now — a fenced code
        // block or a table lays out inside the same text view as everything else, rather than in
        // its own non-wrapping region; only `.codeBlockContent` below still marks code out visually.
        attributed.setAttributes([.font: bodyFont, .foregroundColor: text], range: full)

        // A wrapped list item's continuation lines align under the item's own text rather than
        // restarting at the margin — Obsidian's own behaviour, and native TextKit's own way to
        // get it: `headIndent` is resolved during layout using the real, proportional font
        // metrics, so there is no separate pixel-measurement pass to keep in step with the font.
        if showsHangingIndent {
            for indent in MarkdownHangingIndent.indents(for: source) {
                let range = NSRange(location: indent.location, length: indent.length)
                guard range.upperBound <= attributed.length else { continue }
                let markerRange = NSRange(location: indent.location, length: indent.markerWidth)
                guard markerRange.upperBound <= attributed.length else { continue }
                // The real marker text, not a placeholder — a run of digits and a run of spaces
                // are not the same width in a proportional font, and neither is a tab.
                let marker = (source as NSString).substring(with: markerRange)
                let style = NSMutableParagraphStyle()
                style.headIndent = (marker as NSString).size(withAttributes: [.font: bodyFont]).width
                attributed.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }

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
