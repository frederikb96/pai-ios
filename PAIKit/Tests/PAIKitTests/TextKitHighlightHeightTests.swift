// Apple-only, same reason `TextKitBlockMeasurer.swift` itself is (`Package.swift`'s
// `applePlatformOnly`): this exercises real TextKit, which Linux does not have. The whole file
// compiles to nothing there rather than failing, so the free runner still builds a green suite —
// this assertion only ever runs on the Mac workflow.
#if canImport(UIKit)

    import UIKit
    import XCTest

    @testable import PAIKit

    /// Proves the claim `TranscriptTextHighlighting.apply`'s own doc comment makes: painting a
    /// search highlight (a background colour, and for the current hit a foreground colour too)
    /// never changes what a width the text was already measured at wraps to.
    ///
    /// That is what licenses leaving highlight attributes out of `BlockHeightCache`'s key —
    /// the cheaper choice while search is open, since a hit's card would otherwise measure again
    /// on every keystroke that moves the current match. This is the check that earns it: if a
    /// future highlight ever adds an attribute that DOES affect layout (bold, a different font,
    /// tracking), this fails and the key has to change with it.
    final class TextKitHighlightHeightTests: XCTestCase {

        /// The exact recipe `TextKitBlockMeasurer.textHeight(of:width:)` uses — classic TextKit's
        /// `NSLayoutManager`/`NSTextContainer`, not `NSAttributedString.boundingRect(with:)`, so
        /// this measures on the same machinery a real cell draws with rather than a shortcut that
        /// could disagree with it.
        private func textHeight(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
            let storage = NSTextStorage(attributedString: attributed)
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            return manager.usedRect(for: container).height.rounded(.up)
        }

        /// Long enough to wrap several times at the narrow width below — a single short line
        /// would pass this test by accident even if a highlight attribute genuinely widened its
        /// glyphs, since there would be no wrap point for that to move.
        private static let paragraph =
            "The quick brown fox jumps over the lazy dog while the transcript search highlights "
            + "every occurrence of a word without ever changing how the paragraph wraps around it, "
            + "which is the whole point of painting rather than inserting."

        private func plainAttributed() -> NSAttributedString {
            NSAttributedString(
                string: Self.paragraph,
                attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
            )
        }

        /// Same text, same font, with a highlight painted over one run in the middle and another
        /// (the "current" hit's stronger treatment) near the end — mirroring
        /// `TranscriptTextHighlighting.apply`'s own two cases exactly, `.hit` and `.currentHit`.
        private func highlightedAttributed() -> NSAttributedString {
            let text = Self.paragraph as NSString
            let attributed = NSMutableAttributedString(
                string: Self.paragraph,
                attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
            )
            let hitRange = text.range(of: "occurrence of a word")
            let currentHitRange = text.range(of: "painting rather than inserting")
            XCTAssertNotEqual(hitRange.location, NSNotFound)
            XCTAssertNotEqual(currentHitRange.location, NSNotFound)
            attributed.addAttribute(.backgroundColor, value: UIColor.yellow, range: hitRange)
            attributed.addAttribute(.backgroundColor, value: UIColor.orange, range: currentHitRange)
            attributed.addAttribute(.foregroundColor, value: UIColor.white, range: currentHitRange)
            return attributed
        }

        func testHighlightAttributesDoNotChangeMeasuredHeight() {
            let width: CGFloat = 240

            let plainHeight = textHeight(of: plainAttributed(), width: width)
            let highlightedHeight = textHeight(of: highlightedAttributed(), width: width)

            XCTAssertEqual(
                plainHeight, highlightedHeight,
                "background/foreground colour must be paint-only — a difference here means a "
                    + "highlight attribute is affecting layout, and BlockHeightCache's key needs "
                    + "to include highlight state before this can be trusted")
        }

        /// The same claim at a second width, since a wrap point genuinely moving is what this
        /// test exists to catch — one width alone could coincide with a wrap boundary that hides
        /// a real difference.
        func testHighlightAttributesDoNotChangeMeasuredHeightAtANarrowerWidth() {
            let width: CGFloat = 140

            let plainHeight = textHeight(of: plainAttributed(), width: width)
            let highlightedHeight = textHeight(of: highlightedAttributed(), width: width)

            XCTAssertEqual(plainHeight, highlightedHeight)
        }
    }

#endif
