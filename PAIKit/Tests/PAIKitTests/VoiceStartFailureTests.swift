import XCTest

@testable import PAIKit

/// `VoiceStartFailure.classify` is the one place a status code becomes a user-facing category —
/// a refactor that collapses 503/502/403 back into one generic case would compile cleanly and
/// still pass every test that only checks "an error happened", which is why each case here
/// asserts the specific category rather than just non-nil.
final class VoiceStartFailureTests: XCTestCase {

    func test503ClassifiesAsKeyNotConfigured() {
        XCTAssertEqual(
            VoiceStartFailure.classify(PaiError.detail("no key", statusCode: 503)), .keyNotConfigured
        )
    }

    func test502ClassifiesAsServiceUnavailableCarryingTheDetailText() {
        XCTAssertEqual(
            VoiceStartFailure.classify(PaiError.detail("upstream rejected", statusCode: 502)),
            .serviceUnavailable("upstream rejected")
        )
    }

    func test403ClassifiesAsNotPermitted() {
        XCTAssertEqual(
            VoiceStartFailure.classify(PaiError.detail("not an owner", statusCode: 403)), .notPermitted
        )
    }

    /// A status this contract does not document (400, a bad purpose, say) must not silently land
    /// in one of the three named buckets — that would tell the user the wrong specific thing is
    /// wrong.
    func testUndocumentedStatusFallsIntoOtherRatherThanANamedBucket() {
        let error = PaiError.detail("bad purpose", statusCode: 400)
        XCTAssertEqual(VoiceStartFailure.classify(error), .other(error))
    }

    func testHttpVariantWithoutABodyStillClassifiesByStatusCode() {
        XCTAssertEqual(
            VoiceStartFailure.classify(PaiError.http(statusCode: 503, reason: "Service Unavailable")),
            .keyNotConfigured
        )
    }

    func testTransportFailureIsOther() {
        let error = PaiError.transport("no network")
        XCTAssertEqual(VoiceStartFailure.classify(error), .other(error))
    }

    /// A non-`PaiError` (a `CancellationError`, say) must not crash the classifier via a forced
    /// cast — it falls into `.other` like any undocumented failure.
    func testNonPaiErrorDoesNotCrashAndFallsIntoOther() {
        struct SomeOtherError: Error {}
        guard case .other = VoiceStartFailure.classify(SomeOtherError()) else {
            return XCTFail("expected .other for a non-PaiError")
        }
    }

    // MARK: - userMessage

    /// The one case with real conditional logic: the backend's own detail text wins when it sent
    /// one, since that is more specific than any fixed wording this client could write.
    func testServiceUnavailableUsesTheBackendDetailWhenPresent() {
        XCTAssertEqual(VoiceStartFailure.serviceUnavailable("upstream rejected").userMessage, "upstream rejected")
    }

    func testServiceUnavailableFallsBackToAFixedMessageWhenNoDetailWasSent() {
        XCTAssertEqual(
            VoiceStartFailure.serviceUnavailable(nil).userMessage, "Speech-to-text is unavailable right now.")
    }

    /// `.other` must read through to the wrapped `PaiError`'s own message rather than restating a
    /// fixed string — otherwise a transport error's actual detail (network unreachable, say) gets
    /// thrown away in favour of something generic.
    func testOtherDelegatesToTheWrappedErrorsOwnMessage() {
        let error = PaiError.transport("no network")
        XCTAssertEqual(VoiceStartFailure.other(error).userMessage, error.userMessage)
    }
}
