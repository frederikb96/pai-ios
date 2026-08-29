import XCTest

@testable import PAIKit

/// Decodes every fixture into the model the app will actually use.
///
/// This is the assertion the fixture corpus exists for. The fixtures were written from the
/// backend's contract and the models were derived from it independently, so a disagreement here
/// is a real bug in one of the two — which is the whole reason they were built separately.
///
/// The structural tests next to these check the JSON is well-formed. Only this file checks that
/// the Swift can read it.
final class FixtureDecodingTests: XCTestCase {

    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, from json: String, _ label: String) throws -> T {
        do {
            return try decoder.decode(type, from: PaiFixtures.data(json))
        } catch {
            XCTFail("\(label) did not decode as \(type): \(error)")
            throw error
        }
    }

    // MARK: - Sessions

    func testEverySessionStateFixtureDecodes() throws {
        let cases: [(String, String)] = [
            (PaiFixtures.sessionReady, "ready"),
            (PaiFixtures.sessionStarting, "starting"),
            (PaiFixtures.sessionClosed, "closed"),
            (PaiFixtures.sessionSubagent, "subagent"),
            (PaiFixtures.sessionLaptopReady, "laptop ready"),
            (PaiFixtures.sessionLaptopStarting, "laptop starting"),
            (PaiFixtures.sessionMinimalDiscovered, "minimal discovered"),
            (PaiFixtures.sessionAttentionNotRegistered, "attention not_registered"),
            (PaiFixtures.sessionAttentionUnknown, "attention unknown"),
            (PaiFixtures.sessionBlockedTrust, "blocked trust"),
            (PaiFixtures.sessionBlockedTrustConfirmed, "blocked trust confirmed"),
            (PaiFixtures.sessionBlockedLogin, "blocked login"),
            (PaiFixtures.sessionBlockedChoice, "blocked choice"),
            (PaiFixtures.sessionBlockedPermission, "blocked permission"),
        ]
        for (json, label) in cases {
            _ = try decode(Session.self, from: json, label)
        }
    }

    func testTheMinimalSessionDecodesWithoutTheOptionalFields() throws {
        // A discovered session carries almost nothing. If a field the backend omits is
        // non-optional in Swift, the whole list fails to decode rather than one row.
        let session = try decode(Session.self, from: PaiFixtures.sessionMinimalDiscovered, "minimal")
        XCTAssertFalse(session.id.isEmpty)
    }

    func testASubagentSessionKeepsItsMachineAndItsKindApart() throws {
        let session = try decode(Session.self, from: PaiFixtures.sessionSubagent, "subagent")
        XCTAssertEqual(session.kind, .subagent)
        // The two concepts share the word "agent" in the API and are unrelated. A CodingKeys
        // mixup shows up here as a machine slug that went missing, not as a decode failure.
        XCTAssertNotNil(session.agent)
    }

    func testSessionsPageAndSearchResultsDecode() throws {
        // `GET /api/sessions` returns a bare array; the cursor rides an HTTP header, which is
        // why `SessionsPage` is assembled by the client rather than decoded.
        let sessions = try decode([Session].self, from: PaiFixtures.sessions, "sessions")
        XCTAssertGreaterThan(sessions.count, 1)
        _ = try decode([Session].self, from: PaiFixtures.emptySessions, "empty sessions")
        _ = try decode([SessionSearchResult].self, from: PaiFixtures.sessionSearchResults, "search results")
        _ = try decode([SessionSearchResult].self, from: PaiFixtures.emptySearchResults, "empty search")
    }

    // MARK: - Machines and session types

    func testMachinesDecodeIncludingTheEmptyCase() throws {
        let machines = try decode([Machine].self, from: PaiFixtures.agents, "machines")
        XCTAssertFalse(machines.isEmpty)
        // The backend also sends a `backfill` object that neither the web nor this client reads.
        // Decoding must ignore it rather than fail, which is what this asserts by succeeding.
        _ = try decode([Machine].self, from: PaiFixtures.emptyAgents, "empty machines")
        _ = try decode([SessionType].self, from: PaiFixtures.sessionTypes, "session types")
    }

    // MARK: - Transcript

    func testTheWholeTranscriptDecodes() throws {
        let messages = try decode([Message].self, from: PaiFixtures.transcript, "transcript")
        // The corpus deliberately covers every message type and subtype. A silently-dropped
        // row would leave this short without failing anything else.
        XCTAssertGreaterThan(messages.count, 20)
        _ = try decode([Message].self, from: PaiFixtures.emptyMessages, "empty transcript")
    }

    // MARK: - Everything else the app reads

    func testTheRemainingResponseShapesDecode() throws {
        _ = try decode(MeResponse.self, from: PaiFixtures.me, "me")
        _ = try decode(Usage.self, from: PaiFixtures.usage, "usage")
        _ = try decode(Usage.self, from: PaiFixtures.usageEmpty, "empty usage")
        _ = try decode([Draft].self, from: PaiFixtures.drafts, "drafts")
        _ = try decode([Draft].self, from: PaiFixtures.emptyDrafts, "empty drafts")
        _ = try decode(SecretStatusMap.self, from: PaiFixtures.secretStatuses, "secret statuses")
        _ = try decode(VoiceToken.self, from: PaiFixtures.voiceToken, "voice token")
        _ = try decode(HealthResponse.self, from: PaiFixtures.healthOk, "health ok")
        _ = try decode(HealthResponse.self, from: PaiFixtures.healthDegraded, "health degraded")
        _ = try decode(ClaudeAuth.self, from: PaiFixtures.claudeAuthHealthy, "claude auth healthy")
        _ = try decode(ClaudeAuth.self, from: PaiFixtures.claudeAuthSignedOut, "claude auth signed out")
        _ = try decode(ClaudeAuth.self, from: PaiFixtures.claudeAuthUnknown, "claude auth unknown")
        _ = try decode(BrowseResult.self, from: PaiFixtures.browseResult, "browse result")
        _ = try decode([FolderFavorite].self, from: PaiFixtures.folderFavorites, "folder favorites")
    }

    // MARK: - Terminal

    func testTerminalFramesDecodeAndCarryTheLiveFlag() throws {
        // The fixture is a list of separate frame payloads, as they arrive on the wire.
        XCTAssertFalse(PaiFixtures.terminalFrames.isEmpty)
        for (index, json) in PaiFixtures.terminalFrames.enumerated() {
            _ = try decode(TerminalFrameEvent.self, from: json, "terminal frame \(index)")
        }
    }

    func testATerminalFrameWithoutALiveFieldIsTreatedAsLive() throws {
        // `web/src/api/types.ts` declares only `data`, so this shape is what a reader of the type
        // would expect. Defaulting to live is the safe failure: a wrongly-shown "scrolled back"
        // banner is one nothing can clear.
        let frame = try decode(TerminalFrameEvent.self, from: #"{"data":"hello"}"#, "frame without live")
        XCTAssertTrue(frame.live)
    }

    // MARK: - Errors

    func testErrorBodiesDecodeAsTheContractShape() throws {
        // The contract is exactly `{detail: string}`, and both fixtures are that shape — the
        // second is what the client synthesizes when a non-2xx body is not JSON at all, so a
        // caller sees one error type whether the server explained itself or not.
        struct ErrorBody: Decodable { let detail: String }
        let known = try decode(ErrorBody.self, from: PaiFixtures.errorSessionNotActive, "session not active")
        XCTAssertEqual(known.detail, "session_not_active")

        let synthesized = try decode(ErrorBody.self, from: PaiFixtures.errorNonJsonFallback, "non-JSON fallback")
        XCTAssertFalse(synthesized.detail.isEmpty)
    }
}
