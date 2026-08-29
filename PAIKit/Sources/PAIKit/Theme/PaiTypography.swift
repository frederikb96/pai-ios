// Guarded so the rest of the package builds on Linux, where CI is free — same reasoning as
// `PaiPalette.swift`, SwiftUI is the Apple-only dependency here too.
#if canImport(SwiftUI)

    import SwiftUI
    #if canImport(UIKit)
        import UIKit
    #endif

    /// Swift port of the type ramp `pai-cloud`'s web renders with. Two sources, both verified
    /// against the installed npm package rather than typed from memory, the same discipline
    /// `PaiPalette` used for the OKLCH semantic colours:
    ///
    /// - the Tailwind utility sizes used directly in components — `text-xs`/`text-sm`/
    ///   `text-base`/`text-2xl` plus `font-medium`/`font-semibold` and `font-mono` — read from
    ///   this project's installed `tailwindcss/theme.css` (`--text-xs: 0.75rem`, and so on,
    ///   16px base) and from a frequency sweep of every `.tsx` file under `web/src` to find which
    ///   size/weight combinations actually recur (`text-sm` alone: 164 uses across 31 files;
    ///   `text-sm font-medium`: 33 uses; and so on down to two single-file headings)
    /// - the `prose-sm` scale `MarkdownContent.tsx` applies to rendered assistant messages
    ///   (`className="prose prose-sm dark:prose-invert"`), read from the installed
    ///   `@tailwindcss/typography` package's `styles.js` — its `sm` modifier sets the 14px base
    ///   font `prose-sm` uses, and its `DEFAULT` block carries the heading weights that don't
    ///   vary by size (h1 800, h2 700, h3/h4 600). Code blocks opt out of `prose` entirely
    ///   (`not-prose`) and are sized directly (`text-sm`, i.e. 14px, monospace from the browser's
    ///   `<pre>`/`<code>` default); inline code stays inside `prose` at `em(12, 14)` = 12px,
    ///   weight 600.
    ///
    /// A handful of near-duplicate weight combinations that occur only once or twice in the web
    /// source (`text-sm font-semibold`: 5 uses, `text-xs font-semibold`: 2 uses) were folded into
    /// the closest recurring tier (`bodyEmphasized`/`captionEmphasized`, both `font-medium`)
    /// rather than given their own named style — the same "used once is just indirection"
    /// standard `PaiPalette`'s semantic layer holds itself to.
    public enum PaiTypography {

        /// One named style: a fixed base point size mirrored exactly from the web (1px treated
        /// as 1pt, the standard native-porting convention), plus a `relativeTo` text style whose
        /// Dynamic Type *growth curve* this size scales along. `relativeTo` is chosen for the
        /// closest curve, not the closest default point size — `.caption` is an exact match at
        /// 12pt, but nothing in Apple's ladder sits at 14pt or 18pt, so `body`/`markdownHeading3`
        /// borrow the curve of the nearest style and keep the base size exact.
        public struct Style: Equatable {
            public let pointSize: CGFloat
            public let weight: Font.Weight
            public let design: Font.Design
            public let relativeTo: Font.TextStyle

            public init(
                pointSize: CGFloat, weight: Font.Weight, design: Font.Design = .default,
                relativeTo: Font.TextStyle
            ) {
                self.pointSize = pointSize
                self.weight = weight
                self.design = design
                self.relativeTo = relativeTo
            }

            /// The SwiftUI `Font` for this style. Dynamic Type-aware on iOS, where `UIFontMetrics`
            /// scales the base size along `relativeTo`'s curve; falls back to a fixed, non-scaling
            /// size where `UIKit` doesn't exist (macOS, which this package only targets so
            /// `swift test` has a fast local loop — the app itself ships iOS only).
            public var font: Font {
                #if canImport(UIKit)
                    let uiFont = Self.resolveUIFont(pointSize: pointSize, weight: weight, design: design)
                    let scaled = UIFontMetrics(forTextStyle: relativeTo.uiKitTextStyle).scaledFont(for: uiFont)
                    return Font(scaled)
                #else
                    return Font.system(size: pointSize, weight: weight, design: design)
                #endif
            }

            #if canImport(UIKit)
                /// The point size this style resolves to for an arbitrary Dynamic Type category —
                /// not necessarily the live one. A synchronous height measurer that caches by size
                /// category needs exactly this: given a category, the size it must lay text out at,
                /// without the app actually being at that category right now.
                public func pointSize(for category: UIContentSizeCategory) -> CGFloat {
                    let traits = UITraitCollection(preferredContentSizeCategory: category)
                    return UIFontMetrics(forTextStyle: relativeTo.uiKitTextStyle)
                        .scaledValue(for: pointSize, compatibleWith: traits)
                }

                private static func resolveUIFont(pointSize: CGFloat, weight: Font.Weight, design: Font.Design)
                    -> UIFont
                {
                    let uiWeight = weight.uiKitWeight
                    if design == .monospaced {
                        return UIFont.monospacedSystemFont(ofSize: pointSize, weight: uiWeight)
                    }
                    return UIFont.systemFont(ofSize: pointSize, weight: uiWeight)
                }
            #endif
        }

        // MARK: - Rendered markdown (prose-sm, verified against @tailwindcss/typography/src/styles.js)

        /// `h1 { fontWeight: 800 }` (DEFAULT block) sized `em(30, 14)` = 30px (`sm` block).
        public static let markdownHeading1 = Style(pointSize: 30, weight: .heavy, relativeTo: .title)
        /// `h2 { fontWeight: 700 }` sized `em(20, 14)` = 20px.
        public static let markdownHeading2 = Style(pointSize: 20, weight: .bold, relativeTo: .title2)
        /// `h3 { fontWeight: 600 }` sized `em(18, 14)` = 18px.
        public static let markdownHeading3 = Style(pointSize: 18, weight: .semibold, relativeTo: .title3)
        /// `h4 { fontWeight: 600 }`, no size override in `sm` — inherits the 14px prose base.
        public static let markdownHeading4 = Style(pointSize: 14, weight: .semibold, relativeTo: .headline)
        /// `prose-sm`'s own base font size (`fontSize: rem(14)`), body weight 400 (unset = normal).
        public static let markdownBody = body
        /// `code { fontWeight: 600 }` sized `em(12, 14)` = 12px — inline code only; code blocks
        /// opt out of `prose` (`not-prose`) and are sized directly, see `markdownCodeBlock`.
        public static let markdownInlineCode = Style(
            pointSize: 12, weight: .semibold, design: .monospaced, relativeTo: .caption)
        /// `MarkdownContent.tsx`'s `not-prose` code block renderer sets `text-sm` directly (14px),
        /// monospace from the browser's `<pre>`/`<code>` default, no explicit weight (400).
        public static let markdownCodeBlock = Style(
            pointSize: 14, weight: .regular, design: .monospaced, relativeTo: .subheadline)

        // MARK: - UI chrome (Tailwind utility sweep across web/src/**/*.tsx)

        /// `text-2xl font-semibold` — the single `<h1>` in `NewSessionView.tsx`, the app's one
        /// full-screen title.
        public static let screenTitle = Style(pointSize: 24, weight: .semibold, relativeTo: .title)
        /// `text-base font-semibold` — the single `<h1>` in `Sidebar.tsx`, the app name header.
        public static let panelTitle = Style(pointSize: 16, weight: .semibold, relativeTo: .headline)
        /// `text-sm`, no weight utility — the dominant UI text size (164 uses across 31 files).
        public static let body = Style(pointSize: 14, weight: .regular, relativeTo: .subheadline)
        /// `text-sm font-medium` — labels, menu items, emphasised inline text (33 uses). Folds in
        /// the rarer `text-sm font-semibold` (5 uses).
        public static let bodyEmphasized = Style(pointSize: 14, weight: .medium, relativeTo: .subheadline)
        /// `text-xs`, no weight utility — the second most common UI text size (41 uses).
        public static let caption = Style(pointSize: 12, weight: .regular, relativeTo: .caption)
        /// `text-xs font-medium` (16 uses). Folds in the rarer `text-xs font-semibold` (2 uses).
        public static let captionEmphasized = Style(pointSize: 12, weight: .medium, relativeTo: .caption)
        /// `text-xs font-mono` — token counts, session hints, usage badges (`TokenCounter.tsx`,
        /// `UsageBadge.tsx`, `SessionActionsMenu.tsx`).
        public static let monoLabel = Style(
            pointSize: 12, weight: .regular, design: .monospaced, relativeTo: .caption)
    }

    extension Font.TextStyle {
        #if canImport(UIKit)
            /// `UIFontMetrics` and SwiftUI's `Font.TextStyle` name the same eleven styles but are
            /// two separate types with no built-in bridge between them.
            fileprivate var uiKitTextStyle: UIFont.TextStyle {
                switch self {
                case .largeTitle: return .largeTitle
                case .title: return .title1
                case .title2: return .title2
                case .title3: return .title3
                case .headline: return .headline
                case .subheadline: return .subheadline
                case .body: return .body
                case .callout: return .callout
                case .footnote: return .footnote
                case .caption: return .caption1
                case .caption2: return .caption2
                @unknown default: return .body
                }
            }
        #endif
    }

    extension Font.Weight {
        #if canImport(UIKit)
            fileprivate var uiKitWeight: UIFont.Weight {
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
        #endif
    }

#endif
