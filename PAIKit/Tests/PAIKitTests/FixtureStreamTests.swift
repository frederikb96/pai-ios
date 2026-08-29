import XCTest

@testable import PAIKit

#if DEBUG

    /// The stream fixtures are the two whose absence is invisible: a screen that renders only what
    /// a stream delivered photographs blank, and a blank screenshot on a metered run looks like a
    /// broken screen rather than a missing fixture.
    final class FixtureStreamTests: XCTestCase {

        func testTheTranscriptStreamParsesAsSseAndCarriesMessages() throws {
            var accumulator = SseEventAccumulator()
            var events: [(name: String, data: String)] = []
            for line in PaiFixtures.sseStream.components(separatedBy: "\n") {
                if let event = accumulator.ingest(line: line) { events.append(event) }
            }

            // Parsed by the same accumulator the real client uses, so a body that only *looks*
            // like SSE fails here rather than at a screenshot.
            XCTAssertEqual(events.map(\.name), ["init", "status", "ping"])

            let initData = try XCTUnwrap(events.first { $0.name == "init" }?.data)
            let event = try JSONDecoder().decode(SseInitEvent.self, from: Data(initData.utf8))
            XCTAssertGreaterThan(event.entries.count, 20)
            XCTAssertFalse(event.hasMore)
        }

        func testTheTerminalStreamParsesIntoScreensWithContent() throws {
            var accumulator = SseEventAccumulator()
            var state = TerminalPaneState.initial
            var frames = 0
            for line in PaiFixtures.terminalStream.components(separatedBy: "\n") {
                guard let event = accumulator.ingest(line: line), event.name == "frame" else { continue }
                frames += 1
                // Decoded through `TerminalFrameEvent` rather than the stream client's own
                // `parseFrame`, which is excluded from Linux builds. That is not a weaker check:
                // `parseFrame` delegates to this same type precisely so the wire shape has one
                // definition.
                let decoded = try JSONDecoder().decode(TerminalFrameEvent.self, from: Data(event.data.utf8))
                state = state.applying(TerminalFrameChunk(data: decoded.data, live: decoded.live))
            }

            XCTAssertGreaterThan(frames, 1)
            // The point of the fixture: the pane has something to draw. A stream that parses into
            // an empty screen photographs identically to no stream at all.
            XCTAssertFalse(state.screen.lines.isEmpty)
            XCTAssertTrue(state.screen.lines.contains { line in line.runs.contains { !$0.text.isEmpty } })
        }
    }

#endif
