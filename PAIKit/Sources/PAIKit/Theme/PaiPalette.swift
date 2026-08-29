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
/// palette mirrors that: it is the raw scale only, and a call site chooses the step per mode,
/// same as the source.
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
/// not v3's familiar `#ef4444`. The values below were computed from that installed package's
/// exact OKLCH definitions via the standard OKLCH → linear-sRGB → sRGB conversion (not typed
/// from memory), and cross-checked only by re-deriving `primary-50`/`primary-100` the same way
/// and confirming they land on the hex already in `index.css`. Worth a visual spot-check
/// against the deployed web app once a Mac exists — the cross-check confirms the arithmetic,
/// not the rendered colour.
public enum PaiPalette {

    // MARK: - Primary (index.css --color-primary-50…900)

    public static let primary50 = "#eff6ff"
    public static let primary100 = "#dbeafe"
    public static let primary200 = "#bfdbfe"
    public static let primary300 = "#93c5fd"
    public static let primary400 = "#60a5fa"
    public static let primary500 = "#3b82f6"
    public static let primary600 = "#2563eb"
    public static let primary700 = "#1d4ed8"
    public static let primary800 = "#1e40af"
    public static let primary900 = "#1e3a8a"

    // MARK: - Surface (index.css --color-surface-50…950)

    public static let surface50 = "#f8fafc"
    public static let surface100 = "#f1f5f9"
    public static let surface200 = "#e2e8f0"
    public static let surface300 = "#cbd5e1"
    public static let surface400 = "#94a3b8"
    public static let surface500 = "#64748b"
    public static let surface600 = "#475569"
    public static let surface700 = "#334155"
    public static let surface800 = "#1e293b"
    public static let surface900 = "#0f172a"
    public static let surface950 = "#020617"

    // MARK: - Semantic: red — errors, destructive actions, signed-out banner, recording dot,
    // `is_error` tool dot, `attention` state

    public static let red50 = "#fef2f2"
    public static let red100 = "#ffe2e2"
    public static let red200 = "#ffc9c9"
    public static let red300 = "#ffa2a2"
    public static let red400 = "#ff6467"
    public static let red500 = "#fb2c36"
    public static let red600 = "#e7000b"
    public static let red700 = "#c10007"
    public static let red800 = "#9f0712"
    public static let red900 = "#82181a"
    public static let red950 = "#460809"

    // MARK: - Semantic: amber — `blocked` state, expiring-credential warning, "scrolled back"
    // terminal, retry rows

    public static let amber50 = "#fffbeb"
    public static let amber200 = "#fee685"
    public static let amber300 = "#ffd230"
    public static let amber400 = "#ffb900"
    public static let amber500 = "#fe9a00"
    public static let amber600 = "#e17100"
    public static let amber700 = "#bb4d00"
    public static let amber800 = "#973c00"
    public static let amber900 = "#7b3306"
    public static let amber950 = "#461901"

    // MARK: - Semantic: green — `ready` state, tool success dot, copy-confirmed checks, low
    // plan usage

    public static let green50 = "#f0fdf4"
    public static let green100 = "#dcfce7"
    public static let green200 = "#b9f8cf"
    public static let green300 = "#7bf1a8"
    public static let green400 = "#05df72"
    public static let green500 = "#00c950"
    public static let green600 = "#00a63e"
    public static let green700 = "#008236"
    public static let green800 = "#016630"
    public static let green900 = "#0d542b"
    public static let green950 = "#032e15"

    // MARK: - Semantic: blue — `starting` state, `trust_prompt_confirmed` status banner

    public static let blue50 = "#eff6ff"
    public static let blue200 = "#bedbff"
    public static let blue300 = "#8ec5ff"
    public static let blue400 = "#51a2ff"
    public static let blue500 = "#2b7fff"
    public static let blue600 = "#155dfc"
    public static let blue700 = "#1447e6"
    public static let blue800 = "#193cb8"
    public static let blue900 = "#1c398e"
    public static let blue950 = "#162456"

    // MARK: - Semantic: yellow — search highlight only

    public static let yellow50 = "#fefce8"
    public static let yellow200 = "#fff085"
    public static let yellow300 = "#ffdf20"
    public static let yellow400 = "#fdc700"
    public static let yellow500 = "#f0b100"
    public static let yellow600 = "#d08700"
    public static let yellow700 = "#a65f00"
    public static let yellow800 = "#894b00"
    public static let yellow900 = "#733e0a"
    public static let yellow950 = "#432004"

    // MARK: - Semantic: orange — session-state dot only

    public static let orange50 = "#fff7ed"
    public static let orange200 = "#ffd6a7"
    public static let orange300 = "#ffb86a"
    public static let orange400 = "#ff8904"
    public static let orange500 = "#ff6900"
    public static let orange600 = "#f54900"
    public static let orange700 = "#ca3500"
    public static let orange800 = "#9f2d00"
    public static let orange900 = "#7e2a0c"
    public static let orange950 = "#441306"

    // MARK: - Literal hex from index.css itself (not part of the Tailwind scale at all)

    /// Search-hit highlight colours. `::highlight()` rules cannot carry padding or a border —
    /// only colour applies — and the web writes these two as literal hex rather than tokens.
    public enum SearchHighlight {
        /// `rgba(250, 204, 21, 0.32)` in `index.css` — every hit except the current one.
        public static let allHits = Color(paiHex: "#facc15").opacity(0.32)
        public static let currentBackground = "#facc15"
        public static let currentForeground = "#1c1917"
    }
}

extension Color {
    /// `PaiPalette` stores hex strings, not `Color` values, so the table above stays a plain,
    /// line-by-line diffable copy of `index.css` rather than a second place hex gets encoded.
    /// Malformed input only ever means a typo in this file, so `.clear` is the release fallback
    /// rather than crashing at launch over a design token — but `assertionFailure` still makes
    /// the typo loud in debug builds and tests, where silently rendering nothing is easy to miss.
    public init(paiHex hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6, let value = UInt32(sanitized, radix: 16) else {
            assertionFailure("Malformed PaiPalette hex literal: \(hex)")
            self = .clear
            return
        }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

#endif
