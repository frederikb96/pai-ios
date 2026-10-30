import XCTest

@testable import PAIKit

final class BashEditDiffTests: XCTestCase {

    private let environment = MeasurementEnvironment(sizeCategoryToken: "")
    private let metrics = MessageLayoutMetrics(
        blockSpacing: 4, activityLineHeight: 17, proseLineHeight: 21, trailerLineHeight: 15)

    private func toolResult(json diff: String?) throws -> ToolResult {
        let tail = diff.map { ", \"bash_edit_diff\": \($0)" } ?? ""
        let json = """
            { "tool_use_id": "t1", "tool_name": "Bash", "content": "done", "is_error": false\(tail) }
            """
        return try JSONDecoder().decode(ToolResult.self, from: Data(json.utf8))
    }

    private func message(_ diff: BashEditDiff?, isError: Bool = false) -> Message {
        let result = ToolResult(
            toolUseId: "t1", toolName: "Bash", content: "done", isError: isError, bashEditDiff: diff)
        return Message(
            id: 1, sessionId: "s", type: .toolResult, subtype: nil, outboxId: nil,
            timestamp: "2026-08-29T00:00:00Z", content: nil, thinking: nil, toolCalls: nil, toolResult: result,
            hookSummary: nil, tokens: nil, origin: nil, originMeta: nil, notificationMarker: nil, createdAt: nil)
    }

    private func file(_ path: String = "/home/someone/repo/a.txt", lines: [String]) -> BashEditDiffFile {
        BashEditDiffFile(
            filePath: path, hunks: [BashEditDiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: lines)])
    }

    // MARK: - Decoding

    func testDecodesWhatClaudeCodeRecords() throws {
        let result = try toolResult(
            json: """
                { "files": [ { "filePath": "/repo/new.txt", "created": true,
                               "hunks": [ { "oldStart": 0, "oldLines": 0, "newStart": 1, "newLines": 1,
                                            "lines": ["+hello"] } ] } ],
                  "moreFiles": 3, "changedFiles": ["new.txt"], "shared": true }
                """)

        let diff = try XCTUnwrap(result.bashEditDiff)
        XCTAssertEqual(diff.files.first?.filePath, "/repo/new.txt")
        XCTAssertEqual(diff.files.first?.created, true)
        XCTAssertEqual(diff.files.first?.hunks.first?.lines, ["+hello"])
        XCTAssertEqual(diff.moreFiles, 3)
        XCTAssertTrue(diff.shared)
        XCTAssertFalse(diff.unavailable)
        XCTAssertFalse(diff.skipped)
    }

    func testAResultWithoutTheKeyHasNoDiff() throws {
        XCTAssertNil(try toolResult(json: nil).bashEditDiff)
        XCTAssertNil(try toolResult(json: "null").bashEditDiff)
    }

    /// Every shape here is one a renamed or restructured upstream field would produce. The result
    /// row has to survive each of them whole; failing the decode would lose the page of messages
    /// it arrived in.
    func testAMalformedDiffCostsTheDiffAndNeverTheResult() throws {
        let malformed = [
            "\"a string\"",
            "{ \"moreFiles\": 1 }",
            "{ \"files\": \"nope\" }",
            "{ \"files\": [ { \"filePath\": \"/a\" } ] }",
            "{ \"files\": [ { \"path\": \"/a\", \"hunks\": [] } ] }",
            "{ \"files\": [ { \"filePath\": \"/a\", \"hunks\": [ { \"oldStart\": \"1\" } ] } ] }",
            """
            { "files": [ { "filePath": "/a", "hunks": [
              { "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "lines": ["no prefix"] } ] } ] }
            """,
            """
            { "files": [ { "filePath": "/a", "hunks": [
              { "oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "lines": [""] } ] } ] }
            """,
            "{ \"files\": [], \"moreFiles\": \"two\" }",
        ]
        for json in malformed {
            let result = try toolResult(json: json)
            XCTAssertNil(result.bashEditDiff, json)
            XCTAssertEqual(result.content, "done", json)
        }
    }

    func testARoundTripKeepsTheDiffUnderItsWireKeys() throws {
        let original = ToolResult(
            toolUseId: "t1", toolName: "Bash", content: "done", isError: false,
            bashEditDiff: BashEditDiff(files: [file(lines: ["+x"])], moreFiles: 1, unavailable: true))

        let encoded = try JSONEncoder().encode(original)

        XCTAssertEqual(try JSONDecoder().decode(ToolResult.self, from: encoded), original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["bash_edit_diff"])
    }

    // MARK: - Display

    /// A removed line sits at its old number and the lines after it at their new ones, so the two
    /// counters have to advance apart: the second hunk here starts where the first left them out
    /// of step, and three lines of one kind in a row would not show which counter moved.
    func testLinesCarryTheirRealNumbersOnBothSides() {
        let diff = BashEditDiffFile(
            filePath: "/a",
            hunks: [
                BashEditDiffHunk(
                    oldStart: 9, oldLines: 3, newStart: 9, newLines: 2,
                    lines: [" nine", "-ten", "-eleven", "+TEN", " twelve"]),
                BashEditDiffHunk(oldStart: 98, oldLines: 2, newStart: 97, newLines: 3, lines: [" a", "+b", " c"]),
            ])

        let body = BashEditDiffDisplay.body(of: diff)

        XCTAssertEqual(body.gutterWidth, 3)
        XCTAssertEqual(
            body.text.components(separatedBy: "\n"),
            [
                "  9   nine",
                " 10 - ten",
                " 11 - eleven",
                " 10 + TEN",
                " 11   twelve",
                "    ⋯",
                " 97   a",
                " 98 + b",
                " 99   c",
            ])
    }

    /// A shared line starting with `- ` must not read as a removal to the prefix-based painter.
    func testASharedLineThatLooksLikeARemovalKeepsItsOwnColumn() {
        let body = BashEditDiffDisplay.body(of: file(lines: [" - a list item"]))
        XCTAssertEqual(body.text, "1   - a list item")
        XCTAssertFalse(body.text.dropFirst(body.gutterWidth + 1).hasPrefix("- "))
    }

    func testGitsNoNewlineRemarkIsNotALineOfTheFile() {
        let body = BashEditDiffDisplay.body(of: file(lines: ["-old", "\\ No newline at end of file", "+new"]))
        XCTAssertEqual(body.text, "1 - old\n1 + new")
    }

    func testTheLabelCountsLinesAndNamesWhatHappened() {
        XCTAssertEqual(BashEditDiffDisplay.label(for: file(lines: ["-a", "+b", "+c", " d"])), "Updated +2 -1")
        let created = BashEditDiffFile(filePath: "/a", hunks: [], created: true)
        XCTAssertEqual(BashEditDiffDisplay.label(for: created), "Created +0 -0")
        let deleted = BashEditDiffFile(filePath: "/a", hunks: [], deleted: true)
        XCTAssertEqual(BashEditDiffDisplay.label(for: deleted), "Deleted +0 -0")
    }

    func testTheNoteNamesOnlyWhatApplies() {
        XCTAssertNil(BashEditDiffDisplay.note(for: BashEditDiff(files: [file(lines: ["+x"])])))
        XCTAssertEqual(
            BashEditDiffDisplay.note(for: BashEditDiff(files: [], moreFiles: 1)), "1 more file changed")
        XCTAssertEqual(
            BashEditDiffDisplay.note(for: BashEditDiff(files: [], moreFiles: 2, unavailable: true, shared: true)),
            "2 more files changed · part of the diff is unavailable · another command ran here at the same time")
    }

    // MARK: - The row plan

    func testNoDiffLeavesTheResultAsItWas() {
        let cards = TranscriptRowPlan.cards(for: message(nil), isRevealed: { _ in false })
        XCTAssertEqual(cards.count, 1)
        guard case .toolResult = cards[0].kind else { return XCTFail("expected the result, got \(cards[0].kind)") }
    }

    func testAnythingWithNothingToDrawAddsNoCards() {
        let hidden = [
            BashEditDiff(files: [file(lines: ["+x"])], skipped: true),
            BashEditDiff(files: [], unavailable: true),
            BashEditDiff(files: [], shared: true),
            BashEditDiff(files: []),
        ]
        for diff in hidden {
            XCTAssertEqual(TranscriptRowPlan.cards(for: message(diff), isRevealed: { _ in false }).count, 1)
        }
    }

    func testFilesFollowTheResultInOrderAndTheNoteClosesThem() {
        let diff = BashEditDiff(
            files: [file("/home/someone/repo/a.txt", lines: ["+x"]), file("/repo/b.txt", lines: ["-y"])],
            moreFiles: 2)

        let cards = TranscriptRowPlan.cards(for: message(diff, isError: true), isRevealed: { _ in false })

        XCTAssertEqual(cards.count, 4)
        guard case .toolResult = cards[0].kind else { return XCTFail("expected the result first") }
        XCTAssertEqual(cards[0].tone, .error)
        guard case .bashEditDiffFile(let label, let gutter) = cards[1].kind else {
            return XCTFail("expected a file second, got \(cards[1].kind)")
        }
        XCTAssertEqual(label, "Updated +1 -0")
        XCTAssertEqual(gutter, 1)
        XCTAssertEqual(cards[1].header, "~/repo/a.txt")
        XCTAssertEqual(cards[1].tone, .normal)
        XCTAssertEqual(cards[2].header, "/repo/b.txt")
        guard case .bashEditDiffNote = cards[3].kind else { return XCTFail("expected the note last") }
        XCTAssertEqual(cards[3].header, "2 more files changed")
        XCTAssertEqual(cards[3].blocks, [])
    }

    /// A file opens on its own index, so opening one must not unfold the result or its sibling.
    func testEachFileOpensOnItsOwnAndGetsAnEditsBudget() {
        let long = (1...40).map { "+line \($0)" }
        let diff = BashEditDiff(files: [file(lines: long), file(lines: long)])

        let cards = TranscriptRowPlan.cards(for: message(diff), isRevealed: { $0 == 2 })

        XCTAssertEqual(cards[1].preview.hiddenLines, 28)
        XCTAssertEqual(cards[1].preview.totalLines, 40)
        XCTAssertFalse(cards[1].isRevealed)
        XCTAssertTrue(cards[2].isRevealed)
        XCTAssertEqual(cards[2].preview.hiddenLines, 0)
    }

    func testSearchReachesDiffLinesPastThePreviewAndNamesTheirCard() {
        let lines = (1...40).map { $0 == 30 ? "+the needle" : "+line \($0)" }
        let diff = BashEditDiff(files: [file(lines: lines)], shared: true)

        let (hits, _) = TranscriptSearchIndex.hits(in: [message(diff)], query: "needle")

        XCTAssertEqual(hits.map(\.cardIndex), [1])
    }

    // MARK: - Layout

    func testTheNoteReservesNoLabelLine() {
        let diff = BashEditDiff(files: [], moreFiles: 1)
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let measured = TranscriptRowLayout.measure(
            for: message(diff), width: 400, environment: environment, isRevealed: { _ in false }, measurer: measurer,
            cache: cache, metrics: metrics)

        let note = measured[1]
        XCTAssertGreaterThan(note.headerHeight, 0)
        XCTAssertEqual(note.contentHeight, 0)
        XCTAssertEqual(note.height, 2 * TranscriptRowMetrics.activityRowPadding + note.headerHeight)
        XCTAssertEqual(note.offset, measured[0].height)
    }

    func testAFileReservesItsLabelHeaderAndTrailer() {
        let long = (1...40).map { "+line \($0)" }
        let measurer = StubBlockMeasurer()
        let cache = BlockHeightCache()

        let measured = TranscriptRowLayout.measure(
            for: message(BashEditDiff(files: [file(lines: long)])), width: 400, environment: environment,
            isRevealed: { _ in false }, measurer: measurer, cache: cache, metrics: metrics)

        let card = measured[1]
        XCTAssertTrue(card.isTruncated)
        XCTAssertEqual(
            card.height,
            2 * TranscriptRowMetrics.activityRowPadding + metrics.activityLineHeight + card.headerHeight
                + card.contentHeight + metrics.trailerLineHeight)
    }

    // MARK: - The fixture

    func testTheTranscriptFixtureCarriesADiffTheAppDraws() throws {
        let messages = try JSONDecoder().decode([Message].self, from: Data(PaiFixtures.transcript.utf8))
        let diffs = messages.compactMap(\.toolResult?.bashEditDiff)
        XCTAssertEqual(diffs.count, 1)
        XCTAssertTrue(diffs.allSatisfy(BashEditDiffDisplay.isShown))
    }
}
