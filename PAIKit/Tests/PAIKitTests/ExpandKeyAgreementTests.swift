import XCTest

@testable import PAIKit

/// A card asks for an expand key; Settings offers a toggle for every key in its catalogue. If
/// those two vocabularies can diverge, a card is permanently collapsed and nothing in the app can
/// open it — which is invisible until the backend adds a subtype.
final class ExpandKeyAgreementTests: XCTestCase {

    private var catalogueKeys: Set<String> {
        Set(ExpandPreferences.catalogue.flatMap { $0.items.map(\.key) })
    }

    func testEveryKeyACardCanAskForHasAToggle() {
        // Includes a subtype this build has never heard of, which is the case that motivated
        // this: a new backend subtype must resolve to a key Settings already shows.
        let subtypes: [String?] = [
            nil, "", "skill", "context", "command_output", "image", "compact", "compact_summary",
            "hook", "duration", "interrupt", "notification", "scheduled", "some_future_subtype",
        ]
        for subtype in subtypes {
            let key = MessageRouting.systemExpandKey(subtype: subtype)
            XCTAssertTrue(
                catalogueKeys.contains(key),
                "a card asks for \(key) for subtype \(subtype ?? "nil"), and Settings has no toggle for it")
        }
    }

    func testEveryToolKeyACardCanAskForHasAToggle() {
        for name in ["Bash", "Edit", "Write", "Read", "Grep", "Task", "WebFetch", "mcp__x__y", "BrandNewTool"] {
            for isResult in [false, true] {
                let key = MessageRouting.toolExpandKey(name: name, isResult: isResult)
                XCTAssertTrue(
                    catalogueKeys.contains(key),
                    "a card asks for \(key) for tool \(name), and Settings has no toggle for it")
            }
        }
    }

    func testTheTwoDerivationsAgreeRatherThanMerelyBothExisting() {
        // The routing function delegates, so this holds by construction rather than by
        // coincidence — and this test is what would notice if someone reintroduced a second
        // derivation for the sake of a shorter call.
        for subtype in [nil, "", "skill", "not_a_real_subtype"] as [String?] {
            XCTAssertEqual(
                MessageRouting.systemExpandKey(subtype: subtype),
                ExpandPreferences.systemExpandKey(subtype: subtype))
        }
    }
}
