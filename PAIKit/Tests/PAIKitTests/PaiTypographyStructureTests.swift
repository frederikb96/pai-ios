import Foundation
import XCTest

/// Verifies `PaiTypography`'s declared styles against values transcribed directly from the two
/// web sources it claims to mirror — `tailwindcss/theme.css`'s `--text-*` custom properties and
/// `@tailwindcss/typography/src/styles.js`'s `sm`/`DEFAULT` blocks — not from `PaiTypography.swift`
/// itself, so a wrong value in either place shows up as a mismatch. Pure `Foundation`, no
/// SwiftUI: parses the source as text, so it runs on the free Linux runner even though
/// `PaiTypography` itself only compiles under `#if canImport(SwiftUI)`. Same method as
/// `PaiPaletteAssetTests`.
final class PaiTypographyStructureTests: XCTestCase {

    private static let repoRoot =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let typographySource: String = {
        let path = repoRoot.appendingPathComponent(
            "PAIKit/Sources/PAIKit/Theme/PaiTypography.swift")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }()

    private struct ParsedStyle: Equatable {
        let pointSize: Double
        let weight: String
        let design: String
        let relativeTo: String
    }

    /// `design` defaults to `.default` in `Style.init`, so a declaration omitting it has no
    /// `design:` argument at all — captured as an optional group, not a missing style.
    private static let styleDeclarationRegex = try! NSRegularExpression(
        pattern:
            #"public static let (\w+) = Style\(\s*pointSize: (\d+), weight: \.(\w+)(?:, design: \.(\w+))?, relativeTo: \.(\w+)\)"#
    )

    private static let parsedStyles: [String: ParsedStyle] = {
        let range = NSRange(typographySource.startIndex..., in: typographySource)
        var result: [String: ParsedStyle] = [:]
        styleDeclarationRegex.matches(in: typographySource, range: range).forEach { match in
            func group(_ index: Int) -> String? {
                guard let r = Range(match.range(at: index), in: typographySource) else { return nil }
                return String(typographySource[r])
            }
            guard let name = group(1), let sizeString = group(2), let size = Double(sizeString),
                let weight = group(3), let relativeTo = group(5)
            else { return }
            result[name] = ParsedStyle(
                pointSize: size, weight: weight, design: group(4) ?? "default", relativeTo: relativeTo)
        }
        return result
    }()

    /// Guards the fixture itself, same reasoning as `PaiPaletteAssetTests.testPaletteSourceWasFound`.
    func testTypographySourceWasFound() {
        XCTAssertFalse(
            Self.typographySource.isEmpty,
            "could not read PaiTypography.swift under \(Self.repoRoot.path)")
        XCTAssertGreaterThanOrEqual(
            Self.parsedStyles.count, 12,
            "expected at least 12 Style(...) declarations, found \(Self.parsedStyles.count) — "
                + "the extraction regex or the source layout changed")
    }

    /// Cross-checks every `Style(...)` declaration against sizes and weights transcribed directly
    /// from `tailwindcss/theme.css` (`--text-xs: 0.75rem` = 12px, 16px base, and so on) and from
    /// `@tailwindcss/typography/src/styles.js`'s `sm`/`DEFAULT` blocks (`h1: {fontWeight: '800'}`
    /// sized `em(30, 14)` = 30px, and so on) — the same two files `PaiTypography.swift`'s doc
    /// comments cite.
    func testStylesMatchTailwindSource() {
        let expected: [String: ParsedStyle] = [
            "markdownHeading1": ParsedStyle(pointSize: 30, weight: "heavy", design: "default", relativeTo: "title"),
            "markdownHeading2": ParsedStyle(pointSize: 20, weight: "bold", design: "default", relativeTo: "title2"),
            "markdownHeading3": ParsedStyle(
                pointSize: 18, weight: "semibold", design: "default", relativeTo: "title3"),
            "markdownHeading4": ParsedStyle(
                pointSize: 14, weight: "semibold", design: "default", relativeTo: "headline"),
            "markdownInlineCode": ParsedStyle(
                pointSize: 12, weight: "semibold", design: "monospaced", relativeTo: "caption"),
            "markdownCodeBlock": ParsedStyle(
                pointSize: 14, weight: "regular", design: "monospaced", relativeTo: "subheadline"),
            "screenTitle": ParsedStyle(pointSize: 24, weight: "semibold", design: "default", relativeTo: "title"),
            "panelTitle": ParsedStyle(pointSize: 16, weight: "semibold", design: "default", relativeTo: "headline"),
            "body": ParsedStyle(pointSize: 14, weight: "regular", design: "default", relativeTo: "subheadline"),
            "bodyEmphasized": ParsedStyle(
                pointSize: 14, weight: "medium", design: "default", relativeTo: "subheadline"),
            "caption": ParsedStyle(pointSize: 12, weight: "regular", design: "default", relativeTo: "caption"),
            "captionEmphasized": ParsedStyle(
                pointSize: 12, weight: "medium", design: "default", relativeTo: "caption"),
            "monoLabel": ParsedStyle(
                pointSize: 12, weight: "regular", design: "monospaced", relativeTo: "caption"),
        ]

        for (name, expectedStyle) in expected {
            let actual = Self.parsedStyles[name]
            XCTAssertEqual(actual, expectedStyle, "\(name) does not match the transcribed web source")
        }
    }

    /// `markdownBody` is documented as an alias for `body` rather than a duplicate `Style(...)`
    /// literal — the prose base and the UI body text are the same 14px/regular/subheadline triple,
    /// and writing it twice would just be a second place for one of the two to drift.
    func testMarkdownBodyAliasesBody() {
        XCTAssertTrue(
            Self.typographySource.contains("public static let markdownBody = body"),
            "expected markdownBody to alias body rather than redeclare an identical Style(...)"
        )
    }
}
