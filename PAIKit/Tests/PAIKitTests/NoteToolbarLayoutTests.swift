import Foundation
import XCTest

@testable import PAIKit

/// `NoteToolbarLayout.sanitize(rawIds:)` is what stands between a stored formatting-bar layout
/// and a build that no longer recognises one of its entries — a build that added or removed an
/// action, or a value corrupted some other way. Every case here is a way that boundary can fail
/// silently: dropping the whole arrangement instead of the one bad entry, inventing an action
/// nobody asked for, or losing a deliberate order to a naive union with the default.
final class NoteToolbarLayoutTests: XCTestCase {

    func testUnknownIdIsDroppedWithoutDisturbingTheRestOfTheArrangement() {
        // "future" stands in for an action a newer build added and this one has never heard of —
        // the same shape an OLDER build's removed action takes when this build reads it back.
        let sanitized = NoteToolbarLayout.sanitize(rawIds: ["bold", "future", "quote"])
        XCTAssertEqual(sanitized, [.bold, .quote])
    }

    func testAllUnknownIdsFallBackToTheDefaultLayoutRatherThanAnEmptyBar() {
        let sanitized = NoteToolbarLayout.sanitize(rawIds: ["future", "alsoFuture"])
        XCTAssertEqual(sanitized, NoteToolbarLayout.defaultLayout)
    }

    func testNeverStoredFallsBackToTheDefaultLayout() {
        XCTAssertEqual(NoteToolbarLayout.sanitize(rawIds: []), NoteToolbarLayout.defaultLayout)
    }

    /// A duplicate collapses to its first occurrence — protects against a corrupted or
    /// hand-edited stored value putting the same button in the bar twice.
    func testDuplicateIdCollapsesToItsFirstOccurrence() {
        let sanitized = NoteToolbarLayout.sanitize(rawIds: ["bold", "italic", "bold"])
        XCTAssertEqual(sanitized, [.bold, .italic])
    }

    /// A minimal, deliberately non-default selection is respected exactly as given — never padded
    /// out with `defaultLayout`'s own actions. Catches an implementation that unions the stored
    /// layout with the default instead of trusting a genuinely custom one.
    func testANonDefaultSelectionIsNotPaddedWithDefaultActions() {
        let sanitized = NoteToolbarLayout.sanitize(rawIds: ["link"])
        XCTAssertEqual(sanitized, [.link])
    }

    /// The order given is preserved — sanitizing is a filter, not a re-sort into
    /// `allActionsInDefaultOrder`'s own order.
    func testOrderIsPreservedRatherThanRenormalized() {
        let sanitized = NoteToolbarLayout.sanitize(rawIds: ["link", "undo", "bold"])
        XCTAssertEqual(sanitized, [.link, .undo, .bold])
    }

    /// Every action the default layout names is one this editor can actually perform — a `command`
    /// mapping to `nil` for a default action would leave a button on screen that does nothing.
    func testDefaultLayoutActionsAllMapToARealMarkdownCommandOrAKnownNonCommandAction() {
        for id in NoteToolbarLayout.defaultLayout {
            switch id {
            case .undo, .redo, .attach:
                continue
            default:
                XCTAssertNotNil(
                    id.command, "\(id) has no MarkdownCommand and is not one of the three non-command actions")
            }
        }
    }

    /// `allActionsInDefaultOrder` is the settings screen's exhaustive catalogue — silently
    /// dropping a case there would make an action permanently unreachable from the "Available"
    /// list once disabled.
    func testAllActionsInDefaultOrderNamesEveryCase() {
        XCTAssertEqual(Set(NoteToolbarLayout.allActionsInDefaultOrder), Set(NoteToolbarActionId.allCases))
    }
}
