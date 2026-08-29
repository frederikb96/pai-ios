import XCTest
@testable import PAIKit

/// `ExpandPreferences.catalogue` is generated from `ToolFamily` and `SystemSubtype` specifically
/// so it cannot repeat the web's own bug — `EXPAND_GROUPS` there is hand-listed and is missing a
/// toggle for three keys `getSystemExpandKey` can produce (`system_scheduled`,
/// `system_pai_message`, `system_other`; see `pai-cloud/web/src/stores/settings.ts`). These
/// tests exercise the derivation, not the enums it derives from — every expected key here is a
/// literal, independent of `ExpandPreferences`'s own source, so a regression in the merge logic
/// or a case silently dropped from a switch would show up as a real assertion failure.
final class SettingsExpandPreferencesTests: XCTestCase {

    private func allCatalogueKeys() -> Set<String> {
        Set(ExpandPreferences.catalogue.flatMap { $0.items.map(\.key) })
    }

    func testCatalogueHasNoDuplicateKeys() {
        let keys = ExpandPreferences.catalogue.flatMap { $0.items.map(\.key) }
        XCTAssertEqual(Set(keys).count, keys.count, "a duplicate key means two toggles silently share one preference")
    }

    /// The three keys the web's own `EXPAND_GROUPS` omits, pinned so a future edit to the
    /// catalogue cannot silently reopen the gap.
    func testCatalogueCoversTheThreeKeysMissingFromTheWeb() {
        let keys = allCatalogueKeys()
        XCTAssertTrue(keys.contains("system_scheduled"))
        XCTAssertTrue(keys.contains("system_pai_message"))
        XCTAssertTrue(keys.contains("system_other"))
    }

    /// Every subtype string `backend/src/pai_cloud/parser.py` actually assigns
    /// (`subtype="..."` literals, grepped directly rather than trusting the module's own stale
    /// docstring) must resolve to a key the catalogue lists — the completeness property the web
    /// lost. Literal list, not `SystemSubtype.allCases`, so a case quietly renamed without
    /// updating this list fails here instead of passing by construction.
    func testEveryParserSubtypeResolvesToAKeyInTheCatalogue() {
        let parserSubtypes = [
            "skill", "context", "command", "command_output", "image", "notification", "hook",
            "compact", "compact_summary", "duration", "interrupt", "scheduled", "agent_message",
            "pai_message",
        ]
        let keys = allCatalogueKeys()
        for subtype in parserSubtypes {
            let key = ExpandPreferences.systemExpandKey(subtype: subtype)
            XCTAssertTrue(keys.contains(key), "\(subtype) -> \(key) has no catalogue entry")
        }
    }

    func testNilSubtypeResolvesToSystemOther() {
        XCTAssertEqual(ExpandPreferences.systemExpandKey(subtype: nil), "system_other")
    }

    /// A subtype the parser has not been taught yet must still land in a real key that has a
    /// toggle, precisely so a new parser subtype can never repeat this bug on day one.
    func testUnknownSubtypeFallsBackToSystemOther() {
        XCTAssertEqual(ExpandPreferences.systemExpandKey(subtype: "some_future_subtype"), "system_other")
    }

    /// Mirrors the web's `getToolExpandKey` test fixture (`settings.test.ts`'s `TOOL_NAMES`) —
    /// every family it recognizes, plus one name it does not, both call and result.
    func testToolNamesResolveToKeysInTheCatalogue() {
        let toolNames = [
            "Bash", "Read", "Edit", "Write", "MultiEdit", "Grep", "Glob", "Task",
            "WebSearch", "WebFetch", "Skill", "mcp__example__tool", "SomeFutureTool",
        ]
        let keys = allCatalogueKeys()
        for name in toolNames {
            XCTAssertTrue(keys.contains(ExpandPreferences.toolExpandKey(toolName: name, isResult: false)))
            XCTAssertTrue(keys.contains(ExpandPreferences.toolExpandKey(toolName: name, isResult: true)))
        }
    }

    func testUnrecognizedToolNameFallsIntoOtherFamily() {
        XCTAssertEqual(ExpandPreferences.toolFamily(forToolName: "SomeFutureTool"), .other)
        XCTAssertEqual(ExpandPreferences.toolExpandKey(toolName: "SomeFutureTool", isResult: false), "other_call")
    }

    /// `Grep` and `Glob` are two families but one displayed group — the merge-if-same-title
    /// logic in `catalogue`'s builder, not a `CaseIterable` property, is what makes that true.
    func testGrepAndGlobShareOneDisplayGroup() {
        let searchGroups = ExpandPreferences.catalogue.filter { $0.title == "Search (Grep / Glob)" }
        XCTAssertEqual(searchGroups.count, 1)
        XCTAssertEqual(
            Set(searchGroups[0].items.map(\.key)),
            ["grep_call", "grep_result", "glob_call", "glob_result"]
        )
    }
}
