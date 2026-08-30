// Apple-only, and excluded from the Linux build via `Package.swift`'s `applePlatformOnly` list —
// the same arrangement `Networking/PaiSseClient.swift` and `Networking/PaiTerminalStreamClient.swift`
// already use for code this package needs but cannot prove on the free runner. `BlockMeasuring`
// and every other `Layout/` file stay Apple-agnostic on purpose; this is the one production
// conformance that cannot be.
#if canImport(UIKit)

    import Foundation
    import SwiftUI
    import UIKit

    /// The real ``BlockMeasuring`` conformance: turns a ``MarkdownBlock`` into an
    /// `NSAttributedString` and asks TextKit how tall it lays out at a given width.
    ///
    /// Classic TextKit (`NSLayoutManager`/`NSTextContainer`/`NSTextStorage`), not TextKit 2 —
    /// deliberately the boring, long-proven path rather than the newer one. Per the `scrolling`
    /// skill's third law, the sturdy mechanism is worth more than the clever one exactly when
    /// nothing here can be proven by a compiler running this file (`Tooling/parse-swift.sh` checks
    /// only syntax); classic TextKit's `usedRect(for:)` has been the standard way to measure text
    /// without drawing it since iOS 7, with no compiler feedback in this session to catch a subtler
    /// mistake in a newer API's setup.
    ///
    /// A `.table` block is measured by ``MarkdownTableLayout`` instead of TextKit — GFM tables have
    /// no usable TextKit representation on iOS, and a table cell never wraps (it scrolls
    /// horizontally, matching the web), so its height needs no real text layout at all. That is the
    /// one case this package proves completely; every other case here is unverified until it runs
    /// on Apple hardware, same as `MessageContentLayoutComposerTests`' own stub says of itself.
    public struct TextKitBlockMeasurer: BlockMeasuring {
        public init() {}

        public func height(of block: MarkdownBlock, width: Double, environment: MeasurementEnvironment) -> Double {
            switch block {
            case .table(let table):
                return MarkdownTableLayout.height(
                    for: table, rowHeight: Self.tableRowHeight(for: environment),
                    rowSpacing: TranscriptRowMetrics.tableRowSpacing,
                    dividerHeight: TranscriptRowMetrics.tableDividerHeight)

            case .thematicBreak:
                return TranscriptRowMetrics.thematicBreakHeight

            case .codeBlock(_, let code):
                // Measured by line count rather than by TextKit, for the same reason a table is:
                // the block does not wrap. It scrolls sideways inside its own container, matching
                // the web's `overflow-x-auto` on every `<pre>`, so its height is the same at every
                // width — and exact, rather than the result of a layout pass this package cannot
                // run on Linux.
                //
                // The padding is inside what the block visually occupies, not outside it, so it
                // adds to the measured height here and to the drawn box in `MarkdownContentView`.
                guard !code.isEmpty else { return 0 }
                return MarkdownCodeBlockLayout.height(
                    for: code, lineHeight: Self.codeLineHeight(for: environment),
                    padding: TranscriptRowMetrics.codeBlockPadding)

            case .blockQuote(let blocks):
                return NestedBlockLayout.blockQuoteHeight(
                    blocks, width: width, environment: environment, measurer: self)

            case .list(let list):
                return NestedBlockLayout.listHeight(list, width: width, environment: environment, measurer: self)

            default:
                let attributed = Self.attributedString(for: block, environment: environment)
                guard attributed.length > 0 else { return 0 }
                return Self.textHeight(of: attributed, width: width)
            }
        }

        // MARK: - TextKit measurement

        /// The same `NSLayoutManager`/`NSTextContainer` pair a real cell would use to draw this
        /// text, not `NSAttributedString.boundingRect(with:)` — so a future drawing path built on
        /// the same machinery cannot silently disagree with what this measured.
        private static func textHeight(of attributed: NSAttributedString, width: Double) -> Double {
            let storage = NSTextStorage(attributedString: attributed)
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            // Rounded up: a fractional pixel reported as fitting is a fractional pixel of text
            // clipped on a real screen, and the whole point of this type is that nothing here
            // ever hands back a height the row turns out to be too short for.
            return Double(manager.usedRect(for: container).height.rounded(.up))
        }

        // MARK: - Attributed string per block kind

        /// One block's own text, as TextKit will lay it out. `.blockQuote` and `.list` are not
        /// among the cases this actually builds a string for — their nested blocks are measured
        /// through ``NestedBlockLayout`` instead, recursively, at the narrower width each level
        /// draws at, so `height(of:width:environment:)` never reaches this for either kind.
        private static func attributedString(for block: MarkdownBlock, environment: MeasurementEnvironment)
            -> NSAttributedString
        {
            let category = UIContentSizeCategory(rawValue: environment.sizeCategoryToken)
            switch block {
            case .paragraph(let text):
                return attributed(inline: text, style: PaiTypography.markdownBody, category: category)
            case .heading(let level, let text):
                return attributed(inline: text, style: headingStyle(level), category: category)
            case .codeBlock(_, let code):
                return NSAttributedString(
                    string: code, attributes: attributes(for: PaiTypography.markdownCodeBlock, category: category))
            case .htmlBlock(let raw):
                return NSAttributedString(
                    string: raw, attributes: attributes(for: PaiTypography.markdownCodeBlock, category: category))
            case .blockQuote, .list, .table, .thematicBreak:
                // Each of these is handled before this is ever reached: `.blockQuote`/`.list` in
                // `height(of:width:environment:)`'s own cases above, `.table`/`.thematicBreak` in
                // its cases at the top of the same switch.
                return NSAttributedString(string: "")
            }
        }

        private static func attributed(
            inline text: InlineText, style: PaiTypography.Style, category: UIContentSizeCategory
        )
            -> NSAttributedString
        {
            let result = NSMutableAttributedString()
            for run in text.runs {
                result.append(
                    NSAttributedString(
                        string: run.text, attributes: attributes(for: style, category: category, inlineStyle: run.style)
                    ))
            }
            return result
        }

        private static func headingStyle(_ level: Int) -> PaiTypography.Style {
            switch level {
            case 1: return PaiTypography.markdownHeading1
            case 2: return PaiTypography.markdownHeading2
            case 3: return PaiTypography.markdownHeading3
            default: return PaiTypography.markdownHeading4
            }
        }

        // MARK: - Fonts

        private static func attributes(
            for style: PaiTypography.Style, category: UIContentSizeCategory, inlineStyle: InlineStyle = []
        ) -> [NSAttributedString.Key: Any] {
            let pointSize = style.pointSize(for: category)
            var font = resolveFont(style: style, pointSize: pointSize, monospaced: inlineStyle.contains(.code))
            var traits: UIFontDescriptor.SymbolicTraits = []
            if inlineStyle.contains(.bold) { traits.insert(.traitBold) }
            if inlineStyle.contains(.italic) { traits.insert(.traitItalic) }
            if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: descriptor, size: pointSize)
            }
            var result: [NSAttributedString.Key: Any] = [.font: font]
            if inlineStyle.contains(.strikethrough) {
                result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            return result
        }

        private static func resolveFont(style: PaiTypography.Style, pointSize: CGFloat, monospaced: Bool = false)
            -> UIFont
        {
            let weight = style.weight.textKitWeight
            if monospaced || style.design == .monospaced {
                return UIFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
            }
            return UIFont.systemFont(ofSize: pointSize, weight: weight)
        }

        // MARK: - Non-text blocks

        /// One row's text height, header or data — `GfmTableView` adds no padding of its own
        /// around a cell's text, only the spacing and divider ``MarkdownTableLayout`` takes as
        /// separate parameters.
        /// One line's height inside a fenced block, resolved the same way a table row's is so the
        /// two non-wrapping blocks answer Dynamic Type identically.
        private static func codeLineHeight(for environment: MeasurementEnvironment) -> Double {
            let category = UIContentSizeCategory(rawValue: environment.sizeCategoryToken)
            let pointSize = PaiTypography.markdownCodeBlock.pointSize(for: category)
            let font = resolveFont(style: PaiTypography.markdownCodeBlock, pointSize: pointSize)
            return Double(font.lineHeight.rounded(.up))
        }

        private static func tableRowHeight(for environment: MeasurementEnvironment) -> Double {
            let category = UIContentSizeCategory(rawValue: environment.sizeCategoryToken)
            let pointSize = PaiTypography.markdownBody.pointSize(for: category)
            let font = resolveFont(style: PaiTypography.markdownBody, pointSize: pointSize)
            return Double(font.lineHeight.rounded(.up))
        }
    }

    extension Font.Weight {
        /// A second, file-scoped mapping rather than reaching for `PaiTypography.swift`'s own —
        /// that one is declared `fileprivate` there.
        fileprivate var textKitWeight: UIFont.Weight {
            switch self {
            case .ultraLight: return .ultraLight
            case .thin: return .thin
            case .light: return .light
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            case .heavy: return .heavy
            case .black: return .black
            default: return .regular
            }
        }
    }

#endif
