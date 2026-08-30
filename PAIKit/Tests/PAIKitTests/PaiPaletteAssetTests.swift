import Foundation
import XCTest

/// Verifies the `.xcassets` colour sets on disk actually contain what `PaiPalette` expects,
/// without needing SwiftUI or Xcode to resolve them — a typo in an asset name or a malformed
/// JSON file would otherwise surface only as an invisible colour at runtime, on macOS only, the
/// first time someone actually looks at the screen. Pure `Foundation`, no SwiftUI: this reads
/// `PaiPalette.swift` and the asset catalog as text and JSON, so it runs on the free Linux
/// runner too, unlike the palette itself.
final class PaiPaletteAssetTests: XCTestCase {

    /// This test file lives at `PAIKit/Tests/PAIKitTests/`, four directories below the repo
    /// root; `PaiPalette.swift` lives at `PAIKit/Sources/PAIKit/Theme/`, the same depth.
    private static let repoRoot =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let colorsRoot = repoRoot.appendingPathComponent("PAI/Assets.xcassets/Colors")

    private static let paletteSource: String = {
        let path = repoRoot.appendingPathComponent("PAIKit/Sources/PAIKit/Theme/PaiPalette.swift")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }()

    /// Every asset name `PaiPalette` references, extracted from its own source text rather than
    /// duplicated as a literal list here — the point of this test is to catch drift between the
    /// Swift surface and the asset catalog, not to restate one of them.
    private static let referencedNames: [String] = {
        guard let regex = try? NSRegularExpression(pattern: #"Color\("([a-zA-Z0-9]+)"\)"#) else {
            return []
        }
        let range = NSRange(paletteSource.startIndex..., in: paletteSource)
        return regex.matches(in: paletteSource, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: paletteSource) else { return nil }
            return String(paletteSource[matchRange])
        }
    }()

    private struct ColorSetContents: Decodable {
        struct ColorEntry: Decodable {
            struct ColorValue: Decodable {
                struct Components: Decodable {
                    let red: String
                    let green: String
                    let blue: String
                    let alpha: String
                }
                let components: Components
                enum CodingKeys: String, CodingKey {
                    case colorSpace = "color-space"
                    case components
                }
                let colorSpace: String
            }
            struct Appearance: Decodable {
                let appearance: String
                let value: String
            }
            let idiom: String
            let color: ColorValue
            let appearances: [Appearance]?
        }
        let colors: [ColorEntry]
    }

    /// Guards the fixture itself: an empty extraction would make every test below vacuously pass
    /// on zero names, which reads as green while checking nothing.
    func testPaletteSourceWasFound() {
        XCTAssertFalse(
            Self.paletteSource.isEmpty,
            "could not read PaiPalette.swift under \(Self.repoRoot.path)"
        )
        XCTAssertGreaterThan(
            Self.referencedNames.count,
            100,
            "expected ~108 Color(name:) references (86 raw + 22 semantic), found "
                + "\(Self.referencedNames.count) — the extraction regex or the source layout changed"
        )
    }

    /// The raw scale (`Colors/<Family>/`) never varies by appearance, so a well-formed entry
    /// there is a single universal colour. `Colors/Semantic/` and `Colors/Notes/` are the
    /// opposite: every entry must carry a genuine light AND dark appearance, or the whole point of
    /// those layers — no `colorScheme` branching at the call site — silently stops holding.
    /// The asset families whose values genuinely differ between light and dark. Everything else
    /// is a fixed swatch and a per-appearance variant there would be a duplicate, not a fix.
    private static let appearanceVaryingFamilies: Set<String> = ["Semantic", "Notes"]

    func testEveryReferencedAssetHasAWellFormedColorSet() throws {
        for name in Self.referencedNames {
            let colorSetDir = try Self.findColorSet(named: name)
            let decoded = try Self.decodeColorSet(at: colorSetDir)
            let family = colorSetDir.deletingLastPathComponent().lastPathComponent
            let variesByAppearance = Self.appearanceVaryingFamilies.contains(family)

            if variesByAppearance {
                XCTAssertEqual(
                    decoded.colors.count, 2,
                    "\(name): expected a light entry and a dark-appearance entry")
                let darkEntries = decoded.colors.filter {
                    $0.appearances?.contains { $0.appearance == "luminosity" && $0.value == "dark" }
                        ?? false
                }
                XCTAssertEqual(
                    darkEntries.count, 1,
                    "\(name): expected exactly one entry tagged luminosity/dark")
                let lightEntries = decoded.colors.filter { $0.appearances == nil }
                XCTAssertEqual(
                    lightEntries.count, 1,
                    "\(name): expected exactly one entry with no appearances array (the light default)"
                )
            } else {
                XCTAssertEqual(
                    decoded.colors.count,
                    1,
                    "\(name): expected a single universal entry — none of these values vary by "
                        + "appearance, so a per-appearance variant would be a duplicate, not a fix"
                )
            }

            for entry in decoded.colors {
                XCTAssertEqual(entry.idiom, "universal", "\(name): wrong idiom")
                XCTAssertEqual(entry.color.colorSpace, "srgb", "\(name): wrong color-space")

                let channels = [
                    ("red", entry.color.components.red),
                    ("green", entry.color.components.green),
                    ("blue", entry.color.components.blue),
                    ("alpha", entry.color.components.alpha),
                ]
                for (channel, value) in channels {
                    let parsed = try XCTUnwrap(
                        Double(value), "\(name).\(channel) is not a decimal string: \(value)")
                    XCTAssertTrue(
                        (0...1).contains(parsed), "\(name).\(channel) = \(parsed) is outside 0...1"
                    )
                }
            }
        }
    }

    /// Cross-checks the tokenised half of the palette — the values `index.css` states literally,
    /// as opposed to the OKLCH-derived semantic scale — against the JSON on disk. The expected
    /// hex here is copied directly from `index.css`, not from `PaiPalette.swift`, so a wrong
    /// value in either the generator or a hand-edit of the JSON shows up as a mismatch rather
    /// than agreeing with itself.
    func testTokenisedValuesMatchIndexCss() throws {
        let expected: [(name: String, hex: String, alpha: Double)] = [
            ("primary50", "#eff6ff", 1), ("primary100", "#dbeafe", 1),
            ("primary200", "#bfdbfe", 1), ("primary300", "#93c5fd", 1),
            ("primary400", "#60a5fa", 1), ("primary500", "#3b82f6", 1),
            ("primary600", "#2563eb", 1), ("primary700", "#1d4ed8", 1),
            ("primary800", "#1e40af", 1), ("primary900", "#1e3a8a", 1),
            ("surface50", "#f8fafc", 1), ("surface100", "#f1f5f9", 1),
            ("surface200", "#e2e8f0", 1), ("surface300", "#cbd5e1", 1),
            ("surface400", "#94a3b8", 1), ("surface500", "#64748b", 1),
            ("surface600", "#475569", 1), ("surface700", "#334155", 1),
            ("surface800", "#1e293b", 1), ("surface900", "#0f172a", 1),
            ("surface950", "#020617", 1),
            ("relay500", "#10b981", 1), ("relay600", "#059669", 1),
            ("searchHighlightAllHits", "#facc15", 0.32),
            ("searchHighlightCurrentBackground", "#facc15", 1),
            ("searchHighlightCurrentForeground", "#1c1917", 1),
        ]

        for (name, hex, alpha) in expected {
            let colorSetDir = try Self.findColorSet(named: name)
            let decoded = try Self.decodeColorSet(at: colorSetDir)
            let components = try XCTUnwrap(decoded.colors.first).color.components
            let expectedComponents = Self.hexComponents(hex)

            XCTAssertEqual(
                Double(components.red) ?? -1, expectedComponents.red, accuracy: 0.002,
                "\(name) red")
            XCTAssertEqual(
                Double(components.green) ?? -1, expectedComponents.green, accuracy: 0.002,
                "\(name) green")
            XCTAssertEqual(
                Double(components.blue) ?? -1, expectedComponents.blue, accuracy: 0.002,
                "\(name) blue")
            XCTAssertEqual(
                Double(components.alpha) ?? -1, alpha, accuracy: 0.002, "\(name) alpha")
        }
    }

    // MARK: - Helpers

    private static func findColorSet(named name: String) throws -> URL {
        let familyDirs = try FileManager.default.contentsOfDirectory(
            at: colorsRoot, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants])
        let match =
            familyDirs
            .flatMap { familyDir in
                (try? FileManager.default.contentsOfDirectory(
                    at: familyDir, includingPropertiesForKeys: nil)) ?? []
            }
            .first { $0.lastPathComponent == "\(name).colorset" }
        return try XCTUnwrap(
            match, "\(name).colorset not found under PAI/Assets.xcassets/Colors")
    }

    private static func decodeColorSet(at dir: URL) throws -> ColorSetContents {
        let data = try Data(contentsOf: dir.appendingPathComponent("Contents.json"))
        return try JSONDecoder().decode(ColorSetContents.self, from: data)
    }

    private static func hexComponents(_ hex: String) -> (red: Double, green: Double, blue: Double) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}
