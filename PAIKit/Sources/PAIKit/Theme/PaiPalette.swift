// Guarded so the rest of the package builds on Linux, where CI is free. SwiftUI is the only
// Apple-only dependency here, and nothing outside an app target consumes the palette.
#if canImport(SwiftUI)

    import SwiftUI

    /// Swift port of the design tokens in `pai-cloud/web/src/index.css`: the `@theme` block's
    /// custom properties (`primary`/`surface`), plus the semantic red/amber/green/blue/yellow/orange
    /// scale used directly as Tailwind utility classes there and never tokenised. A palette covering
    /// only the `@theme` block is missing half the UI. `pai-cloud` owns this palette; this file
    /// mirrors it — see `docs/IOS_PARITY.md` there.
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

        // MARK: - Semantic (light/dark pairs, mirrored from web/src/**/*.tsx's `bg-X dark:Y` usage)

        /// Named UI roles, each an asset-catalog colour set with a genuine light AND dark
        /// appearance entry — unlike the raw scale above, whose values never vary by appearance.
        /// The web never tokenises these either: every component picks its own light/dark pair
        /// inline (`bg-surface-50 dark:bg-surface-900`, and so on), so a view here would otherwise
        /// have to branch on `colorScheme` by hand at every call site, once per component. These
        /// exist to make that branching unnecessary — a call site reaches for `.textPrimary` and
        /// the asset catalog resolves the pair for the system appearance.
        ///
        /// Names and pairings come from a frequency sweep of `web/src/**/*.tsx` (`__tests__`
        /// excluded), counting exact `PROPERTY-light dark:PROPERTY-dark` pairs with no other
        /// modifier (`hover:`, `focus:`, …) — those don't port to a touch UI and were excluded.
        /// The web is inconsistent with itself: several near-identical pairs recur for what's
        /// clearly the same role (`text-surface-500 dark:text-surface-400` in 19 files vs.
        /// `text-surface-600 dark:text-surface-400` in 14, both reading as "muted text"). Rather
        /// than name every variant, the most frequent exact pair became the named colour and the
        /// rest were folded into it — each fold recorded on the property it landed on. A pairing
        /// used in only one or two files was named only where it fills a role no other named
        /// colour covers (the warning/error banner text and backgrounds); otherwise it was left
        /// unnamed — `PaiPalette`'s raw scale is still there for a one-off call site.
        public enum Semantic {

            // MARK: Background

            /// `bg-white dark:bg-surface-950` — the outermost full-screen containers (`App.tsx`,
            /// `ErrorBoundary.tsx`, `AppPage.tsx`), 3 files.
            public static let screenBackground = Color("screenBackground")
            /// `bg-white dark:bg-surface-900` — modals, panels and overlays sitting above
            /// `screenBackground`, 10 files. A shallower dark value than `screenBackground` reads
            /// as "raised" the same way a lighter shadow would in light mode.
            public static let panelBackground = Color("panelBackground")
            /// `bg-surface-100 dark:bg-surface-800` — inputs, hover rows, elevated blocks, 13
            /// files — the most common non-page background in the app.
            public static let raisedSurface = Color("raisedSurface")
            /// `bg-surface-50 dark:bg-surface-800/50` — subtle inset highlight rows, 3 files. The
            /// 50% alpha on the dark value only is copied as-is from the web; light mode is fully
            /// opaque.
            public static let insetBackground = Color("insetBackground")
            /// `bg-primary-50 dark:bg-primary-900/20` — the active/selected state for a picker
            /// option or nav item, 3 files. Folds in `bg-primary-50 dark:bg-primary-900/30` (1
            /// file), a 10-point-alpha variant of the same role.
            public static let accentBackground = Color("accentBackground")
            /// `bg-amber-50 dark:bg-amber-950/30` — the "blocked" banner background
            /// (`BlockerBanner.tsx`, `ClaudeAuthBanner.tsx`), 2 files.
            public static let warningBackground = Color("warningBackground")
            /// `bg-red-50 dark:bg-red-950/30` — the error/attention banner background, same 2
            /// files. Folds in `bg-red-50 dark:bg-red-950/40` (1 file).
            public static let errorBackground = Color("errorBackground")

            // MARK: Text (visual-weight tiers, strongest to faintest)

            /// `text-surface-900 dark:text-surface-100` — near-maximum contrast, 9 files.
            public static let textStrong = Color("textStrong")
            /// `text-surface-800 dark:text-surface-200` — default emphasised text, 14 files, the
            /// most common of the two strong tiers. Folds in `text-surface-700 dark:text-surface-200`
            /// (2 files).
            public static let textPrimary = Color("textPrimary")
            /// `text-surface-700 dark:text-surface-300` — 8 files.
            public static let textSecondary = Color("textSecondary")
            /// `text-surface-500 dark:text-surface-400` — 19 files, the single most common text
            /// pairing in the app. Folds in `text-surface-600 dark:text-surface-400` (14 files) —
            /// the two are indistinguishable in dark mode and one step apart in light mode.
            public static let textMuted = Color("textMuted")
            /// `text-surface-400 dark:text-surface-500` — the faintest text tier, 12 files. Also
            /// covers `placeholder-surface-400 dark:placeholder-surface-500` (8 files): SwiftUI has
            /// no separate "placeholder colour" CSS property, and the two pairings share identical
            /// values, so a placeholder call site reaches for this rather than a redundant twin.
            public static let textFaint = Color("textFaint")
            /// `text-surface-500 dark:text-surface-500` — 7 files. The one text tier that stays the
            /// same colour across appearance, unlike every other entry here — named separately
            /// because that behaviour is real, not an oversight.
            public static let textConstant = Color("textConstant")
            /// `text-primary-700 dark:text-primary-300` — accent-coloured text, paired with
            /// `accentBackground`, 5 files. Folds in `text-primary-600 dark:text-primary-400` (3
            /// files).
            public static let accentText = Color("accentText")
            /// `text-amber-600 dark:text-amber-400` — general warning text/badges, 4 files.
            public static let warningText = Color("warningText")
            /// `text-amber-900 dark:text-amber-200` — the "blocked" banner's own heading text, 2
            /// files — stronger contrast than `warningText`, a distinct role rather than a fold.
            public static let warningBannerText = Color("warningBannerText")
            /// `text-red-600 dark:text-red-400` — general error text, 5 files. Folds in
            /// `text-red-700 dark:text-red-400` (2 files).
            public static let errorText = Color("errorText")
            /// `text-red-900 dark:text-red-200` — the error banner's own heading text, 2 files,
            /// mirroring `warningBannerText`.
            public static let errorBannerText = Color("errorBannerText")

            // MARK: Border

            /// `border-surface-200 dark:border-surface-800` — the default divider, 18 files, by
            /// far the most common border pairing.
            public static let borderDefault = Color("borderDefault")
            /// `border-surface-200 dark:border-surface-700` — a more visible border for a handful
            /// of prominent boundaries (pickers, modals), 8 files. Folds in
            /// `border-surface-300 dark:border-surface-700` (2 files).
            public static let borderStrong = Color("borderStrong")
            /// `border-red-300 dark:border-red-800` — the error banner's border, 3 files.
            public static let errorBorder = Color("errorBorder")
            /// `border-amber-300 dark:border-amber-800` — the "blocked" banner's border, 2 files.
            public static let warningBorder = Color("warningBorder")
        }
    }

#endif
