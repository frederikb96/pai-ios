import Foundation
import XCTest

/// Cross-checks every `Colors/Semantic/*.colorset` against the raw scale step it claims to mirror
/// (`PaiPalette.Semantic.textMuted` documents itself as `surface500`/`surface400`, for instance) —
/// reads both JSON files from disk independently of `PaiPaletteAssetTests`, so a semantic entry
/// that drifted from the raw step it was generated from, or was hand-edited wrong, shows up as a
/// mismatch. Pure `Foundation`, runs on the free Linux runner.
final class PaiSemanticColorTests: XCTestCase {

    private static let repoRoot =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let colorsRoot = repoRoot.appendingPathComponent("PAI/Assets.xcassets/Colors")
    private static let semanticRoot = colorsRoot.appendingPathComponent("Semantic")

    private struct Components: Decodable, Equatable {
        let red: String
        let green: String
        let blue: String
        let alpha: String
    }

    private struct ColorEntry: Decodable {
        struct Appearance: Decodable {
            let appearance: String
            let value: String
        }
        struct ColorValue: Decodable {
            let components: Components
        }
        let color: ColorValue
        let appearances: [Appearance]?
    }

    private struct ColorSetContents: Decodable {
        let colors: [ColorEntry]
    }

    /// A semantic pairing: the raw step it mirrors in light mode, the raw step in dark mode, and
    /// an alpha override where the web applies one only in dark mode (`dark:bg-primary-900/20`,
    /// and so on) — `nil` means both entries carry the raw step's own alpha unchanged.
    private struct Pairing {
        let name: String
        let lightRawName: String?  // nil for the literal "white" (#ffffff), not part of the raw scale
        let darkRawName: String
        let darkAlphaOverride: Double?
    }

    /// Transcribed directly from the design decisions in `PaiPalette.Semantic`'s doc comments —
    /// independent of the generator that produced the JSON, so a slip in either shows up here.
    private static let pairings: [Pairing] = [
        Pairing(name: "screenBackground", lightRawName: nil, darkRawName: "surface950", darkAlphaOverride: nil),
        Pairing(name: "panelBackground", lightRawName: nil, darkRawName: "surface900", darkAlphaOverride: nil),
        Pairing(
            name: "raisedSurface", lightRawName: "surface100", darkRawName: "surface800",
            darkAlphaOverride: nil),
        Pairing(
            name: "insetBackground", lightRawName: "surface50", darkRawName: "surface800",
            darkAlphaOverride: 0.5),
        Pairing(
            name: "accentBackground", lightRawName: "primary50", darkRawName: "primary900",
            darkAlphaOverride: 0.2),
        Pairing(
            name: "warningBackground", lightRawName: "amber50", darkRawName: "amber950",
            darkAlphaOverride: 0.3),
        Pairing(
            name: "errorBackground", lightRawName: "red50", darkRawName: "red950",
            darkAlphaOverride: 0.3),
        Pairing(
            name: "textStrong", lightRawName: "surface900", darkRawName: "surface100",
            darkAlphaOverride: nil),
        Pairing(
            name: "textPrimary", lightRawName: "surface800", darkRawName: "surface200",
            darkAlphaOverride: nil),
        Pairing(
            name: "textSecondary", lightRawName: "surface700", darkRawName: "surface300",
            darkAlphaOverride: nil),
        Pairing(
            name: "textMuted", lightRawName: "surface500", darkRawName: "surface400",
            darkAlphaOverride: nil),
        Pairing(
            name: "textFaint", lightRawName: "surface400", darkRawName: "surface500",
            darkAlphaOverride: nil),
        Pairing(
            name: "textConstant", lightRawName: "surface500", darkRawName: "surface500",
            darkAlphaOverride: nil),
        Pairing(
            name: "accentText", lightRawName: "primary700", darkRawName: "primary300",
            darkAlphaOverride: nil),
        Pairing(
            name: "warningText", lightRawName: "amber600", darkRawName: "amber400",
            darkAlphaOverride: nil),
        Pairing(
            name: "warningBannerText", lightRawName: "amber900", darkRawName: "amber200",
            darkAlphaOverride: nil),
        Pairing(
            name: "errorText", lightRawName: "red600", darkRawName: "red400", darkAlphaOverride: nil),
        Pairing(
            name: "errorBannerText", lightRawName: "red900", darkRawName: "red200",
            darkAlphaOverride: nil),
        Pairing(
            name: "borderDefault", lightRawName: "surface200", darkRawName: "surface800",
            darkAlphaOverride: nil),
        Pairing(
            name: "borderStrong", lightRawName: "surface200", darkRawName: "surface700",
            darkAlphaOverride: nil),
        Pairing(
            name: "errorBorder", lightRawName: "red300", darkRawName: "red800", darkAlphaOverride: nil),
        Pairing(
            name: "warningBorder", lightRawName: "amber300", darkRawName: "amber800",
            darkAlphaOverride: nil),
    ]

    func testPairingTableCoversEveryColorSetOnDisk() throws {
        let onDisk = try FileManager.default.contentsOfDirectory(
            at: Self.semanticRoot, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "colorset" }
        .map { $0.deletingPathExtension().lastPathComponent }

        XCTAssertEqual(
            Set(onDisk), Set(Self.pairings.map(\.name)),
            "the pairing table above and Colors/Semantic/ on disk must name exactly the same set"
        )
    }

    func testSemanticColorsMatchTheRawStepsTheyMirror() throws {
        for pairing in Self.pairings {
            let semantic = try Self.decode(colorSetNamed: pairing.name, under: Self.semanticRoot)
            let light = try XCTUnwrap(
                semantic.colors.first { $0.appearances == nil }, "\(pairing.name): no light entry")
            let dark = try XCTUnwrap(
                semantic.colors.first {
                    $0.appearances?.contains { $0.appearance == "luminosity" && $0.value == "dark" }
                        ?? false
                }, "\(pairing.name): no dark entry")

            if let lightRawName = pairing.lightRawName {
                let raw = try Self.decode(colorSetNamed: lightRawName, under: Self.colorsRoot)
                let rawComponents = try XCTUnwrap(raw.colors.first).color.components
                XCTAssertEqual(
                    light.color.components, rawComponents,
                    "\(pairing.name) light entry does not match raw \(lightRawName)")
            } else {
                XCTAssertEqual(
                    light.color.components,
                    Components(red: "1.000", green: "1.000", blue: "1.000", alpha: "1.000"),
                    "\(pairing.name) light entry should be literal white")
            }

            let rawDark = try Self.decode(colorSetNamed: pairing.darkRawName, under: Self.colorsRoot)
            let rawDarkComponents = try XCTUnwrap(rawDark.colors.first).color.components
            XCTAssertEqual(
                dark.color.components.red, rawDarkComponents.red, "\(pairing.name) dark red")
            XCTAssertEqual(
                dark.color.components.green, rawDarkComponents.green, "\(pairing.name) dark green")
            XCTAssertEqual(
                dark.color.components.blue, rawDarkComponents.blue, "\(pairing.name) dark blue")

            let expectedAlpha =
                pairing.darkAlphaOverride.map { String(format: "%.3f", $0) }
                ?? rawDarkComponents.alpha
            XCTAssertEqual(dark.color.components.alpha, expectedAlpha, "\(pairing.name) dark alpha")
        }
    }

    private static func decode(colorSetNamed name: String, under root: URL) throws -> ColorSetContents {
        if root == colorsRoot {
            // Raw steps live one level down, inside a family folder (Primary/, Surface/, ...).
            let familyDirs = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
            let match =
                familyDirs
                .flatMap {
                    (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
                }
                .first { $0.lastPathComponent == "\(name).colorset" }
            let dir = try XCTUnwrap(match, "\(name).colorset not found under a raw family folder")
            let data = try Data(contentsOf: dir.appendingPathComponent("Contents.json"))
            return try JSONDecoder().decode(ColorSetContents.self, from: data)
        }
        let dir = root.appendingPathComponent("\(name).colorset")
        let data = try Data(contentsOf: dir.appendingPathComponent("Contents.json"))
        return try JSONDecoder().decode(ColorSetContents.self, from: data)
    }
}
