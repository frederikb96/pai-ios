import XCTest

@testable import PAIKit

/// Decisions drawn inside replies: which lines are markers, where an unembedded decision goes,
/// what each place shows, and the room a card takes in its row.
final class InlineDecisionsTests: XCTestCase {

    // MARK: - Fixtures

    private func message(
        _ id: Int, _ type: MessageType, subtype: String? = nil, at time: String, content: String? = nil
    ) -> Message {
        Message(
            id: id, sessionId: "s", type: type, subtype: subtype, outboxId: nil,
            timestamp: "2026-11-08T\(time)Z", content: content, thinking: nil, toolCalls: nil, toolResult: nil,
            hookSummary: nil, tokens: nil, origin: nil, originMeta: nil, createdAt: nil)
    }

    private func decision(
        _ number: Int, createdAt time: String = "10:00:00", state: DecisionState = .open, answer: String? = nil
    ) -> Decision {
        Decision(
            id: "d\(number)", sessionId: "s", number: number, title: "Title \(number)", recommendation: "yes",
            state: state, answer: answer, createdAt: "2026-11-08T\(time).123456+00:00", updatedAt: "u\(number)")
    }

    // MARK: - Marker grammar

    func testOnlyAWholeLineOutsideAFenceIsAMarker() {
        let reply = """
            Intro line
            {{D1}}
            ```
            {{D2}}
            ```
                {{D3}}
             {{D4}} \t
            not {{D5}}
            ~~~~
            {{D6}}
            ~~~
            {{D7}}
            ~~~~
            {{D8}}
            """
        XCTAssertEqual(DecisionMarkers.embeddedNumbers(in: reply), [1, 4, 8])
        XCTAssertEqual(DecisionMarkers.split(reply).prefix(2), [.markdown("Intro line"), .decision(1)])
    }

    // MARK: - Placing the decisions no reply embeds

    /// Three turns; the second runs a tool between two replies and ends with its duration row, the
    /// third is still running.
    private func threeTurns(withDurationRow: Bool = true) -> [Message] {
        var messages = [
            message(1, .user, at: "10:00:00", content: "first prompt"),
            message(2, .assistant, at: "10:01:00", content: "first reply"),
            message(3, .system, subtype: "duration", at: "10:02:00"),
            message(4, .user, at: "10:05:00", content: "second prompt"),
            message(5, .assistant, at: "10:06:00", content: "looking"),
            message(6, .toolResult, at: "10:06:30"),
            message(7, .assistant, at: "10:07:00", content: "here is what I found"),
            message(8, .system, subtype: "duration", at: "10:08:00"),
            message(9, .user, at: "10:10:00", content: "third prompt"),
            message(10, .assistant, at: "10:11:00", content: "working on it"),
        ]
        if !withDurationRow { messages.removeAll { $0.id == 8 } }
        return messages
    }

    func testAnUnembeddedOpenDecisionGoesUnderTheLastReplyOfTheTurnThatAskedItOnceThatTurnEnded() {
        let decisions = [
            decision(1, createdAt: "10:05:30"),  // before either reply of the second turn
            decision(2, createdAt: "10:10:30"),  // the third turn is still running
            decision(3, createdAt: "10:06:10"),  // embedded by a reply
            decision(4, createdAt: "10:06:20", state: .answered, answer: "yes"),
        ]
        let placed = DecisionMarkers.placeUnembedded(
            messages: threeTurns(), decisions: decisions, embedded: [3], hasOlder: false)
        XCTAssertEqual(placed, [7: [1]])

        let endedByTheNextPrompt = DecisionMarkers.placeUnembedded(
            messages: threeTurns(withDurationRow: false), decisions: decisions, embedded: [3], hasOlder: false)
        XCTAssertEqual(endedByTheNextPrompt, [7: [1]])
    }

    func testNothingIsPlacedWhenTheLoadedRowsMayNotReachBackToTheDecision() {
        let early = [decision(1, createdAt: "09:00:00")]
        // The window starts mid-turn, on a reply: its prompt is in the unloaded page above.
        let placed = DecisionMarkers.placeUnembedded(
            messages: Array(threeTurns().dropFirst(4)), decisions: early, embedded: [], hasOlder: true)
        XCTAssertEqual(placed, [:])
    }

    // MARK: - What a place shows

    func testAPlaceShowsTheMarkerToAGuestNothingUntilReadAndTheDecisionOnceRead() {
        let listed = [
            decision(1, state: .answered, answer: "no"), decision(2, state: .withdrawn), decision(3),
        ]
        XCTAssertEqual(InlineDecisionContext(mayDecide: false, listed: listed).display(for: 3), .marker(number: 3))
        XCTAssertEqual(InlineDecisionContext(mayDecide: true, listed: nil).display(for: 3), .loading)

        let context = InlineDecisionContext(
            mayDecide: true, listed: listed, picks: [3: DecisionPick(text: "yes", updatedAt: "u3")], pendingCount: 2)
        XCTAssertEqual(context.display(for: 9), .marker(number: 9))
        XCTAssertEqual(context.display(for: 1), .resolved(number: 1, title: "Title 1", answer: "no"))
        XCTAssertEqual(context.display(for: 2), .resolved(number: 2, title: "Title 2", answer: nil))
        guard case .open(let open) = context.display(for: 3) else { return XCTFail("D3 is open") }
        XCTAssertEqual(open.picked, "yes")
        XCTAssertEqual(open.pendingCount, 2)
    }

    /// A resolved decision stays one line until the reader opens it; opened, it shows the whole
    /// decision and its row makes room for it. Each decision opens on its own.
    func testAResolvedDecisionTheReaderOpenedShowsItsWholeCard() throws {
        let answered = decision(1, state: .answered, answer: "no")
        let listed = [answered, decision(2, state: .withdrawn)]
        let context = InlineDecisionContext(mayDecide: true, listed: listed, reopened: [1])
        XCTAssertEqual(context.display(for: 1), .reopened(answered))
        XCTAssertEqual(context.display(for: 2), .resolved(number: 2, title: "Title 2", answer: nil))

        let line = try XCTUnwrap(
            cards("{{D1}}", displays: [1: .resolved(number: 1, title: "Title 1", answer: "no")]).first)
        let opened = try XCTUnwrap(cards("{{D1}}", displays: [1: .reopened(answered)]).first)
        XCTAssertGreaterThan(opened.height, line.height)
    }

    // MARK: - The room a card takes

    private let environment = MeasurementEnvironment(sizeCategoryToken: "")
    private let metrics = MessageLayoutMetrics(
        blockSpacing: 4, activityLineHeight: 17, proseLineHeight: 21, trailerLineHeight: 15)

    private func cards(
        _ content: String, displays: [Int: InlineDecisionDisplay] = [:], trailing: [Int] = []
    ) -> [MeasuredCard] {
        TranscriptRowLayout.measure(
            for: message(1, .assistant, at: "10:00:00", content: content), width: 400, environment: environment,
            isRevealed: { _ in true }, measurer: StubBlockMeasurer(), cache: BlockHeightCache(), metrics: metrics,
            decisionDisplays: displays, trailingDecisions: trailing)
    }

    /// Until the session's decisions are read a marker draws nothing, and its row is exactly the
    /// reply without that line: no gap where the card will be.
    func testAMarkerNotReadYetTakesNoRoom() {
        let waiting = cards("Para one.\n{{D3}}\n\nPara two.", displays: [3: .loading])
        let without = cards("Para one.\n\nPara two.")
        XCTAssertEqual(waiting.first?.height, without.first?.height)
        XCTAssertEqual(waiting.first?.blockOffsets, without.first?.blockOffsets)
    }

    /// An open card pushes everything after it down by its own height and one gap — what a
    /// search landing in the paragraph below it scrolls by.
    func testABlockAfterACardMovesDownByTheCard() throws {
        let open = InlineDecisionDisplay.open(
            InlineOpenDecision(decision: decision(3), picked: nil, pendingCount: 0, isSending: false, errorMessage: nil)
        )
        let waiting = try XCTUnwrap(cards("Para one.\n{{D3}}\n\nPara two.", displays: [3: .loading]).first)
        let drawn = try XCTUnwrap(cards("Para one.\n{{D3}}\n\nPara two.", displays: [3: open]).first)
        let card = try XCTUnwrap(drawn.decisions.first)

        XCTAssertGreaterThan(card.measured.height, 0)
        XCTAssertEqual(card.offset, waiting.blockOffsets[1], accuracy: 0.001, "where the next paragraph began")
        XCTAssertEqual(drawn.blockOffsets[1], waiting.blockOffsets[1] + card.measured.height + 4, accuracy: 0.001)
        XCTAssertEqual(drawn.height, waiting.height + card.measured.height + 4, accuracy: 0.001)
    }

    /// The search index plans a row without decisions; a row drawn with one placed under it must
    /// still have the same blocks at the same indices, or a hit would land on the wrong text.
    func testATrailingDecisionLeavesTheReplysBlocksWhereTheSearchIndexPlansThem() throws {
        let reply = "Para one.\n{{D3}}\n\nPara two."
        let planned = TranscriptRowPlan.cards(for: message(1, .assistant, at: "10:00:00", content: reply)) { _ in true }
        let drawn = try XCTUnwrap(cards(reply, displays: [3: .loading, 5: .marker(number: 5)], trailing: [5]).first)
        XCTAssertEqual(planned.count, 1)
        XCTAssertEqual(drawn.plan.blocks, planned[0].blocks)
        XCTAssertEqual(drawn.plan.decisionSlots.map(\.number), [3, 5])
        XCTAssertEqual(drawn.plan.decisionSlots.last?.position, drawn.plan.blocks.count)
    }
}
