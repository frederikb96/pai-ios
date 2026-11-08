// Apple-only, and excluded from the Linux build via `Package.swift`'s `applePlatformOnly` list,
// like `TextKitBlockMeasurer.swift`: SwiftMath draws with CoreText into a UIKit view.
#if canImport(UIKit)

    import Foundation
    @preconcurrency import SwiftMath
    import UIKit

    /// A formula (``MarkdownMath``) typeset once per LaTeX, style and text size, for both the
    /// measurer and the view that draws it: they read the same cached result, so the height a row
    /// reserves for a formula is the height of the image drawn in it.
    ///
    /// `nil` is the answer for LaTeX SwiftMath cannot parse; both sides then show the source as
    /// code instead (``inlineFallback(_:)``, a code block for a display formula).
    @MainActor
    public enum MathTypesetter {

        public enum Style: Sendable {
            /// Inside a line of prose, sitting on its baseline.
            case inline
            /// A block of its own, in TeX's display style.
            case display
        }

        /// One typeset formula: a template image, so it takes the colour of the text around it,
        /// and where its baseline sits.
        ///
        /// Unchecked because `UIImage` is immutable and documented safe to use from any thread.
        public struct Formula: @unchecked Sendable {
            public let image: UIImage
            /// From the top of the image down to the baseline.
            public let ascent: Double
            /// From the baseline down to the bottom of the image.
            public let descent: Double

            public var width: Double { Double(image.size.width) }
            public var height: Double { ascent + descent }
        }

        /// How much larger than the prose around it a formula is set. Latin Modern, the math font,
        /// reads smaller than the system font at the same point size.
        private static let inlineScale = 1.1
        private static let displayScale = 1.2

        public static func formula(_ latex: String, style: Style, environment: MeasurementEnvironment) -> Formula? {
            let category = UIContentSizeCategory(rawValue: environment.sizeCategoryToken)
            let scale = style == .display ? displayScale : inlineScale
            let pointSize = (PaiTypography.markdownBody.pointSize(for: category) * scale).rounded()
            let key = "\(style == .display ? "d" : "i") \(pointSize) \(latex)" as NSString
            if let entry = cache.object(forKey: key) { return entry.formula }
            let formula = typeset(latex, style: style, pointSize: pointSize)
            cache.setObject(Entry(formula), forKey: key)
            return formula
        }

        /// What an inline formula SwiftMath cannot parse shows instead: its source, in the inline
        /// code font.
        public nonisolated static func inlineFallback(_ latex: String) -> String {
            "$\(latex)$"
        }

        // MARK: - Typesetting

        /// A failure is cached too, so a formula that does not parse is tried once.
        private final class Entry {
            let formula: Formula?

            init(_ formula: Formula?) {
                self.formula = formula
            }
        }

        private static let cache: NSCache<NSString, Entry> = {
            let cache = NSCache<NSString, Entry>()
            cache.countLimit = 1000
            return cache
        }()

        private static func typeset(_ latex: String, style: Style, pointSize: CGFloat) -> Formula? {
            let label = MTMathUILabel()
            label.labelMode = style == .display ? .display : .text
            label.textAlignment = .left
            label.fontSize = pointSize
            label.textColor = .black
            label.latex = latex
            guard label.error == nil else { return nil }
            let natural = label.intrinsicContentSize
            guard natural.width > 0, natural.height > 0 else { return nil }
            // The label centres a formula shorter than half its font size in a box that tall,
            // which would lift it off the baseline; a box at least that tall keeps the baseline
            // exactly `descent` above the bottom.
            let size = CGSize(
                width: natural.width.rounded(.up), height: max(natural.height, pointSize / 2).rounded(.up))
            label.frame = CGRect(origin: .zero, size: size)
            label.setNeedsLayout()
            label.layoutIfNeeded()
            guard let display = label.displayList else { return nil }
            let image = UIGraphicsImageRenderer(size: size).image { context in
                // SwiftMath draws in CoreGraphics' upward coordinates.
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                label.draw(label.bounds)
            }
            let descent = Double(display.descent) + Double(size.height - max(natural.height, pointSize / 2)) / 2
            return Formula(
                image: image.withRenderingMode(.alwaysTemplate), ascent: Double(size.height) - descent,
                descent: descent)
        }
    }

#endif
