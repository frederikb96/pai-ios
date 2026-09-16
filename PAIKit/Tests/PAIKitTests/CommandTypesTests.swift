import XCTest

@testable import PAIKit

final class CommandTypesTests: XCTestCase {

    /// `CommandKind` is the only `Codable` type in this file — `CommandObservation`/`CommandEvent`
    /// are live pipeline values with nowhere they need to persist, the same reasoning
    /// `ConnectionHealthEvent` and `FeedbackEvent` already follow.
    func testCommandKindRoundTripsForEveryCase() throws {
        for kind in CommandKind.allCases {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(CommandKind.self, from: data), kind)
        }
    }

    /// `WakeWordCommandGate` looks a classifier's output name straight back up into a
    /// `CommandKind` — this round trip is what makes that lookup exact rather than approximate.
    func testModelNameRoundTripsForEveryCase() {
        for kind in CommandKind.allCases {
            XCTAssertEqual(CommandKind(modelName: kind.modelName), kind)
        }
    }

    func testModelNameIsTheKaiPrefixPlusTheRawCaseName() {
        XCTAssertEqual(CommandKind.start.modelName, "kai_start")
        XCTAssertEqual(CommandKind.end.modelName, "kai_end")
    }

    func testAnUnrecognisedModelNameDecodesToNilRatherThanCrashing() {
        XCTAssertNil(CommandKind(modelName: "kai_mute"), "removed as a command; must not resurrect")
        XCTAssertNil(CommandKind(modelName: "not_even_the_right_prefix"))
    }
}
