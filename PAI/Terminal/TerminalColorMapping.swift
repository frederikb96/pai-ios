import PAIKit
import SwiftUI

/// Maps a parsed terminal color (the 16-slot SGR table, a 256-color index, or truecolor) to a
/// concrete `Color` — the mapping `TerminalStyle.swift` deliberately leaves undone, since
/// resolving to a hex value is a theme decision, not a parsing one.
///
/// The 16-slot table below is `xterm.js`'s own `DEFAULT_ANSI_COLORS`
/// (`xterm.js/src/browser/Types.ts`), not a palette invented here — `TerminalView.tsx`'s theme
/// object only overrides background/foreground/cursor/selection and leaves the ANSI colors at
/// xterm.js's built-in default, so matching those exact values is what makes this pane read the
/// same as the web's for the same escape codes.
enum TerminalColorMapping {

    // MARK: - Pane chrome (mirrors `TerminalView.tsx`'s DARK_XTERM_THEME/LIGHT_XTERM_THEME)

    /// `#0f172a` (surface-900) in dark, `#ffffff` in light — exact hex match confirmed against
    /// `PAI/Assets.xcassets/Colors/Surface/surface900.colorset`.
    static func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? PaiPalette.surface900 : .white
    }

    /// `#e2e8f0` (surface-200) in dark, `#1e293b` (surface-800) in light — same exact-match
    /// reasoning as `background(for:)`.
    static func foreground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? PaiPalette.surface200 : PaiPalette.surface800
    }

    // MARK: - SGR color resolution

    static func resolve(_ color: TerminalColor) -> Color {
        switch color {
        case .standard(let index):
            return standardPalette[safe: Int(index)] ?? standardPalette[0]
        case .indexed(let index):
            return indexedColor(Int(index))
        case .trueColor(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
    }

    /// `xterm.js`'s `DEFAULT_ANSI_COLORS`, indices 0-15: black, red, green, yellow, blue,
    /// magenta, cyan, white, then the bright variant of each.
    private static let standardPalette: [Color] = [
        Color(hex: 0x2e_3436), Color(hex: 0xcc_0000), Color(hex: 0x4e_9a06), Color(hex: 0xc4_a000),
        Color(hex: 0x34_65a4), Color(hex: 0x75_507b), Color(hex: 0x06_989a), Color(hex: 0xd3_d7cf),
        Color(hex: 0x55_5753), Color(hex: 0xef_2929), Color(hex: 0x8a_e234), Color(hex: 0xfc_e94f),
        Color(hex: 0x72_9fcf), Color(hex: 0xad_7fa8), Color(hex: 0x34_e2e2), Color(hex: 0xee_eeec),
    ]

    /// Indices 16-231 are a 6x6x6 color cube, 232-255 a 24-step greyscale ramp — the same
    /// generation `xterm.js`'s `Types.ts` uses to fill in the rest of its 256-color table.
    private static func indexedColor(_ index: Int) -> Color {
        guard index >= 16 else { return standardPalette[safe: index] ?? standardPalette[0] }
        if index >= 232 {
            let level = 8 + (index - 232) * 10
            return Color(red: Double(level) / 255, green: Double(level) / 255, blue: Double(level) / 255)
        }
        let cubeIndex = index - 16
        let steps = [0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff]
        let r = steps[(cubeIndex / 36) % 6]
        let g = steps[(cubeIndex / 6) % 6]
        let b = steps[cubeIndex % 6]
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

extension Color {
    /// `0xRRGGBB`, for typing the literal hex values above verbatim rather than pre-dividing them.
    fileprivate init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Array {
    /// A malformed SGR index (out of the 0-255 range the parser already clamps to `UInt8`, or a
    /// truncated sequence some other way) degrades to black rather than crashing the view.
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
