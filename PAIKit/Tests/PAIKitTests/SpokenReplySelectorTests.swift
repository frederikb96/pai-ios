import XCTest

@testable import PAIKit

/// Tested against the fixture corpus rather than hand-built `Message` values wherever possible —
/// the same corpus that catches a backend field-name drift, so a change to `Message`'s shape
/// breaks this test before it breaks the app.
final class SpokenReplySelectorTests: XCTestCase {

    private func decodedTranscript() throws -> [Message] {
        try JSONDecoder().decode([Message].self, from: PaiFixtures.data(PaiFixtures.transcript))
    }

    // MARK: - The fixture's own rows

    func testAnAssistantReplyWithContentIsSpeakable() throws {
        let messages = try decodedTranscript()
        let reply = try XCTUnwrap(messages.first { $0.id == 9028 })
        XCTAssertEqual(reply.type, .assistant)
        XCTAssertTrue(SpokenReplySelector.isSpeakable(reply, baseline: 9000, spoken: []))
    }

    func testAnAssistantRowWithEmptyContentIsNotSpeakable() throws {
        let messages = try decodedTranscript()
        let emptyReply = try XCTUnwrap(messages.first { $0.id == 9033 })
        XCTAssertEqual(emptyReply.content, "")
        XCTAssertFalse(SpokenReplySelector.isSpeakable(emptyReply, baseline: 9000, spoken: []))
    }

    func testAThinkingOnlyAssistantRowWithNoContentIsNotSpeakable() throws {
        let messages = try decodedTranscript()
        let thinkingOnly = try XCTUnwrap(messages.first { $0.id == 9003 })
        XCTAssertNil(thinkingOnly.content)
        XCTAssertFalse(SpokenReplySelector.isSpeakable(thinkingOnly, baseline: 9000, spoken: []))
    }

    /// The one row this backend actually sends an `agent_message` subtype on — always
    /// `type == "user"`, never `assistant`. Proves the type check alone already excludes it,
    /// which is why the selector carries no separate `subtype` filter of its own.
    func testARelayedAgentMessageRowIsNotSpeakableBecauseItIsAUserRowNotAnAssistantOne() throws {
        let messages = try decodedTranscript()
        let relayed = try XCTUnwrap(messages.first { $0.id == 9034 })
        XCTAssertEqual(relayed.type, .user)
        XCTAssertEqual(relayed.subtype, "agent_message")
        XCTAssertFalse(SpokenReplySelector.isSpeakable(relayed, baseline: 9000, spoken: []))
    }

    func testAToolResultRowIsNeverSpeakable() throws {
        let messages = try decodedTranscript()
        let toolResult = try XCTUnwrap(messages.first { $0.type == .toolResult })
        XCTAssertFalse(SpokenReplySelector.isSpeakable(toolResult, baseline: 0, spoken: []))
    }

    // MARK: - The replay-trap guard

    func testARowAtOrBeforeTheBaselineIsNotSpeakable() throws {
        let messages = try decodedTranscript()
        let reply = try XCTUnwrap(messages.first { $0.id == 9028 })
        XCTAssertFalse(SpokenReplySelector.isSpeakable(reply, baseline: 9028, spoken: []))
        XCTAssertFalse(SpokenReplySelector.isSpeakable(reply, baseline: 9030, spoken: []))
    }

    func testARowAlreadyInTheSpokenSetIsNotSpokenAgain() throws {
        let messages = try decodedTranscript()
        let reply = try XCTUnwrap(messages.first { $0.id == 9028 })
        XCTAssertFalse(SpokenReplySelector.isSpeakable(reply, baseline: 9000, spoken: [9028]))
    }

    // MARK: - Batch filtering and ordering

    func testSpeakableFiltersAndOrdersABatchByIdRegardlessOfInputOrder() throws {
        let messages = try decodedTranscript()
        let reply1 = try XCTUnwrap(messages.first { $0.id == 9028 })
        let toolResult = try XCTUnwrap(messages.first { $0.type == .toolResult })
        let thinkingOnly = try XCTUnwrap(messages.first { $0.id == 9003 })

        let batch = [toolResult, reply1, thinkingOnly]
        let speakable = SpokenReplySelector.speakable(from: batch, baseline: 9000, spoken: [])

        XCTAssertEqual(speakable.map(\.id), [9028])
    }

    func testTheWholeFixtureTranscriptYieldsEveryContentBearingAssistantRowPastTheBaseline() throws {
        let messages = try decodedTranscript()
        let baseline = 9000
        let speakable = SpokenReplySelector.speakable(from: messages, baseline: baseline, spoken: [])

        let expectedIds =
            messages
            .filter {
                $0.type == .assistant && $0.id > baseline
                    && !($0.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map(\.id)
            .sorted()

        XCTAssertFalse(expectedIds.isEmpty, "the fixture should carry at least one speakable assistant reply")
        XCTAssertEqual(speakable.map(\.id), expectedIds)
    }
}
