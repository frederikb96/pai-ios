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
}
