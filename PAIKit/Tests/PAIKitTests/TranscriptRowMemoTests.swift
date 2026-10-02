import Foundation
import XCTest

@testable import PAIKit

/// `TranscriptRowMemo` is what makes an arriving message cost the same whether the window holds
/// three hundred rows or three thousand. Its two ways to go wrong are opposite and both silent: a
/// memo that remembers too eagerly hands a row a height measured for something it no longer is,
/// which moves every row below it under the reader; one that remembers too little puts the cost
/// back without changing anything anyone can see.
final class TranscriptRowMemoTests: XCTestCase {

    private let environment = MeasurementEnvironment(sizeCategoryToken: "")
    private let metrics = MessageLayoutMetrics(
        blockSpacing: 4, activityLineHeight: 17, proseLineHeight: 21, trailerLineHeight: 15)

    private func reply(_ id: Int, _ content: String, timestamp: String? = "2026-10-01T12:00:00.506812+00:00")
        -> Message
    {
        Message(
            id: id, sessionId: "s", type: .assistant, subtype: nil, outboxId: nil, timestamp: timestamp,
            content: content, thinking: nil, toolCalls: nil, toolResult: nil, hookSummary: nil, tokens: nil,
            origin: nil, originMeta: nil, createdAt: nil)
    }

    /// A tool result long enough that its card is bounded, so opening it changes its height.
    private func toolResult(_ id: Int) -> Message {
        let output = (0..<80).map { "line \($0) of output" }.joined(separator: "\n")
        return Message(
            id: id, sessionId: "s", type: .toolResult, subtype: nil, outboxId: nil, timestamp: nil, content: nil,
            thinking: nil, toolCalls: nil,
            toolResult: ToolResult(toolUseId: "t\(id)", toolName: "Bash", content: output, isError: false),
            hookSummary: nil, tokens: nil, origin: nil, originMeta: nil, createdAt: nil)
    }

    private func inputs(width: Double = 360, revealed: Set<Int> = [], separator: Bool = false)
        -> TranscriptRowMemo.Inputs
    {
        TranscriptRowMemo.Inputs(
            width: width, environment: environment, revealedCards: revealed, hasTimeSeparator: separator)
    }

    /// The measurement the controller would make without a memo.
    private func fresh(_ message: Message, _ inputs: TranscriptRowMemo.Inputs) -> [MeasuredCard] {
        TranscriptRowLayout.measure(
            for: message, width: inputs.width, environment: inputs.environment,
            isRevealed: { inputs.revealedCards.contains($0) }, measurer: StubBlockMeasurer(),
            cache: BlockHeightCache(), metrics: metrics, hasTimeSeparator: inputs.hasTimeSeparator)
    }

    private func pass(_ memo: TranscriptRowMemo, _ messages: [Message], counting measured: inout Int) {
        for message in messages {
            _ = memo.cards(for: message, inputs: inputs()) {
                measured += 1
                return fresh(message, inputs())
            }
        }
    }

    /// The whole point: a pass after an arrival measures the arrival and nothing else.
    func testAPassAfterAnArrivalMeasuresOnlyTheArrival() {
        let memo = TranscriptRowMemo()
        var window = (1...500).map { reply($0, "reply \($0)") }
        var measured = 0
        pass(memo, window, counting: &measured)
        XCTAssertEqual(measured, 500)

        window.append(reply(501, "the new one"))
        measured = 0
        pass(memo, window, counting: &measured)

        XCTAssertEqual(measured, 1)
    }

    /// Every input that shapes a row must reach the key. Each case changes exactly one of them and
    /// expects what a fresh measurement under the new input gives — never the remembered height.
    func testAChangedInputIsMeasuredAfreshRatherThanRemembered() {
        let cases: [(String, Message, TranscriptRowMemo.Inputs, Message, TranscriptRowMemo.Inputs)] = [
            ("card opened", toolResult(7), inputs(), toolResult(7), inputs(revealed: [0])),
            (
                "width", reply(7, String(repeating: "word ", count: 200)), inputs(width: 360),
                reply(7, String(repeating: "word ", count: 200)), inputs(width: 200)
            ),
            ("separator", reply(7, "short"), inputs(separator: false), reply(7, "short"), inputs(separator: true)),
            (
                "content under the same id", reply(-1, "a queued send"), inputs(),
                reply(-1, String(repeating: "a much longer queued send ", count: 40)), inputs()
            ),
        ]
        for (name, before, beforeInputs, after, afterInputs) in cases {
            let memo = TranscriptRowMemo()
            let first = memo.cards(for: before, inputs: beforeInputs) { fresh(before, beforeInputs) }
            let second = memo.cards(for: after, inputs: afterInputs) { fresh(after, afterInputs) }

            XCTAssertEqual(second, fresh(after, afterInputs), name)
            // The fixture itself must be able to tell the two apart, or this case proves nothing.
            XCTAssertNotEqual(
                TranscriptRowLayout.height(
                    of: first, hasTimeSeparator: beforeInputs.hasTimeSeparator, metrics: metrics),
                TranscriptRowLayout.height(
                    of: second, hasTimeSeparator: afterInputs.hasTimeSeparator, metrics: metrics),
                name)
        }
    }

    func testRetainForgetsRowsThatLeftTheWindow() {
        let memo = TranscriptRowMemo()
        var measured = 0
        pass(memo, (1...10).map { reply($0, "r") }, counting: &measured)

        memo.retain(only: Set(6...10))

        XCTAssertEqual(memo.count, 5)
        measured = 0
        pass(memo, (1...10).map { reply($0, "r") }, counting: &measured)
        XCTAssertEqual(measured, 5)
    }

    /// A parsed timestamp is remembered against the string it came from, never just the id.
    func testATimestampIsReparsedWhenItsTextChanges() {
        let memo = TranscriptRowMemo()
        let early = reply(3, "r", timestamp: "2026-10-01T12:00:00.506812+00:00")
        let late = reply(3, "r", timestamp: "2026-10-01T15:30:00.000000+00:00")

        XCTAssertEqual(memo.date(of: early), IsoTimestamp.date(from: early.timestamp!))
        XCTAssertEqual(memo.date(of: late), IsoTimestamp.date(from: late.timestamp!))
        XCTAssertNotNil(memo.date(of: late))
    }
}
