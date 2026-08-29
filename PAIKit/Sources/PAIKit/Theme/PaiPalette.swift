// Guarded so the rest of the package builds on Linux, where CI is free. SwiftUI is the only
// Apple-only dependency here, and nothing outside an app target consumes the palette.
#if canImport(SwiftUI)

    import SwiftUI

    /// Swift port of the design tokens in `pai-cloud/web/src/index.css`: the 21 `@theme` custom
    /// properties (`primary`/`surface`), plus the semantic red/amber/green/blue/yellow/orange scale
    /// used directly as Tailwind utility classes there and never tokenised. A palette covering only
    /// the 21 is missing half the UI. `pai-cloud` owns this palette; this file mirrors it.
    ///
    /// The web picks a step per light/dark pair inline (`bg-surface-50 dark:bg-surface-900`, and
    /// so on for every colour in the app) rather than defining separate light/dark tokens. This
    /// palette mirrors that: every step below is a fixed swatch, identical regardless of system
    /// appearance — same as `index.css`, where `.dark` never changes a token's own value, only
    /// which step a call site reaches for. A call site still chooses the step per mode; only the
    /// *storage* changed, from a hex string parsed at runtime to a named entry in
    /// `PAI/Assets.xcassets/Colors/`, resolved by the asset catalog instead of `Color(paiHex:)`.
    /// The three-state app theme (light / dark / follow system) is a separate concern, handled by
    /// `overrideUserInterfaceStyle` — the colour set format supports per-appearance variants for
    /// that, but none of the values here need one, since none of them varies by appearance.
    ///
    /// `primary`/`surface` are copied verbatim from `index.css`'s hex literals — hand-authored
    /// values that predate this project's Tailwind v4 upgrade and were never re-derived from v4's
    /// own default palette, but `index.css` is what the web actually renders, so it is still the
    /// correct source to copy.
    ///
    /// The semantic red/amber/green/blue/yellow/orange values are different in kind: nothing in this
    /// repo tokenises them, so there was no hex to copy. Tailwind v4 defines its default palette in
    /// OKLCH, not the hex most people remember from v3 — confirmed against this project's own
    /// installed `tailwindcss/dist` package, whose v4 `red-500` is `oklch(63.7% 0.237 25.331)`,
    /// not v3's familiar `#ef4444`. The values were computed from that installed package's exact
    /// OKLCH definitions via the standard OKLCH → linear-sRGB → sRGB conversion (not typed from
    /// memory), and cross-checked by re-deriving `primary-50`/`primary-100` the same way and
    /// confirming they land on the hex already in `index.css`. Worth a visual spot-check against
    /// the deployed web app once a Mac exists — the cross-check confirms the arithmetic, not the
    /// rendered colour.
    public enum PaiPalette {

        // MARK: - Primary (index.css --color-primary-50…900)

        public static let primary50 = Color("primary50")
        public static let primary100 = Color("primary100")
        public static let primary200 = Color("primary200")
        public static let primary300 = Color("primary300")
        public static let primary400 = Color("primary400")
        public static let primary500 = Color("primary500")
        public static let primary600 = Color("primary600")
        public static let primary700 = Color("primary700")
        public static let primary800 = Color("primary800")
        public static let primary900 = Color("primary900")

        // MARK: - Surface (index.css --color-surface-50…950)

        public static let surface50 = Color("surface50")
        public static let surface100 = Color("surface100")
        public static let surface200 = Color("surface200")
        public static let surface300 = Color("surface300")
        public static let surface400 = Color("surface400")
        public static let surface500 = Color("surface500")
        public static let surface600 = Color("surface600")
        public static let surface700 = Color("surface700")
        public static let surface800 = Color("surface800")
        public static let surface900 = Color("surface900")
        public static let surface950 = Color("surface950")

        // MARK: - Semantic: red — errors, destructive actions, signed-out banner, recording dot,
        // `is_error` tool dot, `attention` state

        public static let red50 = Color("red50")
        public static let red100 = Color("red100")
        public static let red200 = Color("red200")
        public static let red300 = Color("red300")
        public static let red400 = Color("red400")
        public static let red500 = Color("red500")
        public static let red600 = Color("red600")
        public static let red700 = Color("red700")
        public static let red800 = Color("red800")
        public static let red900 = Color("red900")
        public static let red950 = Color("red950")

        // MARK: - Semantic: amber — `blocked` state, expiring-credential warning, "scrolled back"
        // terminal, retry rows

        public static let amber50 = Color("amber50")
        public static let amber200 = Color("amber200")
        public static let amber300 = Color("amber300")
        public static let amber400 = Color("amber400")
        public static let amber500 = Color("amber500")
        public static let amber600 = Color("amber600")
        public static let amber700 = Color("amber700")
        public static let amber800 = Color("amber800")
        public static let amber900 = Color("amber900")
        public static let amber950 = Color("amber950")

        // MARK: - Semantic: green — `ready` state, tool success dot, copy-confirmed checks, low
        // plan usage

        public static let green50 = Color("green50")
        public static let green100 = Color("green100")
        public static let green200 = Color("green200")
        public static let green300 = Color("green300")
        public static let green400 = Color("green400")
        public static let green500 = Color("green500")
        public static let green600 = Color("green600")
        public static let green700 = Color("green700")
        public static let green800 = Color("green800")
        public static let green900 = Color("green900")
        public static let green950 = Color("green950")

        // MARK: - Semantic: blue — `starting` state, `trust_prompt_confirmed` status banner

        public static let blue50 = Color("blue50")
        public static let blue200 = Color("blue200")
        public static let blue300 = Color("blue300")
        public static let blue400 = Color("blue400")
        public static let blue500 = Color("blue500")
        public static let blue600 = Color("blue600")
        public static let blue700 = Color("blue700")
        public static let blue800 = Color("blue800")
        public static let blue900 = Color("blue900")
        public static let blue950 = Color("blue950")

        // MARK: - Semantic: yellow — search highlight only

        public static let yellow50 = Color("yellow50")
        public static let yellow200 = Color("yellow200")
        public static let yellow300 = Color("yellow300")
        public static let yellow400 = Color("yellow400")
        public static let yellow500 = Color("yellow500")
        public static let yellow600 = Color("yellow600")
        public static let yellow700 = Color("yellow700")
        public static let yellow800 = Color("yellow800")
        public static let yellow900 = Color("yellow900")
        public static let yellow950 = Color("yellow950")

        // MARK: - Semantic: orange — session-state dot only

        public static let orange50 = Color("orange50")
        public static let orange200 = Color("orange200")
        public static let orange300 = Color("orange300")
        public static let orange400 = Color("orange400")
        public static let orange500 = Color("orange500")
        public static let orange600 = Color("orange600")
        public static let orange700 = Color("orange700")
        public static let orange800 = Color("orange800")
        public static let orange900 = Color("orange900")
        public static let orange950 = Color("orange950")

        // MARK: - Literal hex from index.css itself (not part of the Tailwind scale at all)

        /// Search-hit highlight colours. The web's `::highlight()` rules cannot carry padding or
        /// a border — only colour applies — and `index.css` writes these two as literal hex
        /// rather than tokens.
        public enum SearchHighlight {
            /// `rgba(250, 204, 21, 0.32)` in `index.css` — every hit except the current one. The
            /// 32% alpha is baked into the colour set itself rather than applied with `.opacity`
            /// at the call site, so every consumer gets it automatically.
            public static let allHits = Color("searchHighlightAllHits")
            public static let currentBackground = Color("searchHighlightCurrentBackground")
            public static let currentForeground = Color("searchHighlightCurrentForeground")
        }
    }

#endif
