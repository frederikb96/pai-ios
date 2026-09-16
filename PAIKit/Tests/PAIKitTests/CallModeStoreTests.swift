import XCTest

@testable import PAIKit

/// A ledger a test can mutate between calls into the store — `CallModeStore` only ever reads it
/// through `currentLedger`, never owns or mutates it itself.
private final class LedgerBox: @unchecked Sendable {
    var ledger: TranscriptLedger

    init(_ ledger: TranscriptLedger) {
        self.ledger = ledger
    }
}

/// Records every send attempt, and can be told to fail the next one — the recoverable-failure
/// path `CallModeStore.trySend` falls into on a `postMessage` throw.
private final class SendRecorder: @unchecked Sendable {
    private(set) var sentTexts: [String] = []
    var nextFailure: Error?

    func send(_ text: String) throws {
        if let nextFailure {
            self.nextFailure = nil
            throw nextFailure
        }
        sentTexts.append(text)
    }
}

private struct SendFailure: Error {}

@MainActor
final class CallModeStoreTests: XCTestCase {

    private func emptyLedger(sampleRate: Int = 16000) -> TranscriptLedger {
        TranscriptLedger(takeId: "take-1", mode: .call, sampleRate: sampleRate, draftKey: "session-1", preText: "")
    }

    private func makeStore(
        ledgerBox: LedgerBox, sender: SendRecorder, feedback: @escaping @Sendable (FeedbackEvent) -> Void = { _ in }
    ) -> CallModeStore {
        let dependencies = CallModeDependencies(
            sleep: { _ in },  // instant — the commit-wait loop must not slow tests down
            currentLedger: { ledgerBox.ledger },
            postMessage: { text in try sender.send(text) },
            feedback: feedback
        )
        return CallModeStore(sessionId: "session-1", dependencies: dependencies)
    }

    // MARK: - Entering

    func testEnteringGoesStraightToCollectingNeverToListeningFirst() {
        let store = makeStore(ledgerBox: LedgerBox(emptyLedger()), sender: SendRecorder())
        XCTAssertEqual(store.phase, .idle)

        store.startEntering()
        XCTAssertEqual(store.phase, .entering)

        store.finishEntering(atOffset: 1000)
        XCTAssertEqual(store.phase, .collecting(startOffset: 1000))
    }

    func testFinishEnteringIsIgnoredIfNotCurrentlyEntering() {
        let store = makeStore(ledgerBox: LedgerBox(emptyLedger()), sender: SendRecorder())
        store.finishEntering(atOffset: 1000)
        XCTAssertEqual(store.phase, .idle)
    }

    // MARK: - Start / stop: stop holds, it never sends

    func testStartWhileListeningEntersCollectingAtTheCommandsOffset() async {
        let store = makeStore(ledgerBox: LedgerBox(emptyLedger()), sender: SendRecorder())
        store.startEntering()
        store.finishEntering(atOffset: 0)
        await store.handle(CommandEvent(kind: .stop, atOffset: 0, confidence: 1))  // -> listening
        XCTAssertEqual(store.phase, .listening)

        await store.handle(CommandEvent(kind: .start, atOffset: 500, confidence: 1))
        XCTAssertEqual(store.phase, .collecting(startOffset: 500))
    }

    func testStopReturnsToListeningWithoutSendingAndKeepsTheTextInTheTurn() async {
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: LedgerBox(emptyLedger()), sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)

        await store.handle(CommandEvent(kind: .stop, atOffset: 1000, confidence: 1))

        XCTAssertTrue(sender.sentTexts.isEmpty, "stop must never send — only send does")
        XCTAssertEqual(store.phase, .listening)
        XCTAssertEqual(store.turnRanges, [0..<1000])
    }

    func testStopIsIgnoredWhenNotCurrentlyCollecting() async {
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: LedgerBox(emptyLedger()), sender: sender)
        // Never entered — still `.idle`.
        await store.handle(CommandEvent(kind: .stop, atOffset: 1000, confidence: 1))
        XCTAssertTrue(sender.sentTexts.isEmpty)
        XCTAssertEqual(store.phase, .idle)
    }

    func testASecondStartAfterAStopExtendsTheSameTurnAcrossTwoRanges() async {
        let store = makeStore(ledgerBox: LedgerBox(emptyLedger()), sender: SendRecorder())
        store.startEntering()
        store.finishEntering(atOffset: 0)

        await store.handle(CommandEvent(kind: .stop, atOffset: 500, confidence: 1))
        XCTAssertEqual(store.turnRanges, [0..<500])

        await store.handle(CommandEvent(kind: .start, atOffset: 800, confidence: 1))
        await store.handle(CommandEvent(kind: .stop, atOffset: 1200, confidence: 1))
        XCTAssertEqual(store.turnRanges, [0..<500, 800..<1200], "both collecting stretches belong to one turn")
    }

    // MARK: - Send: from recording mode (stop-and-send), and from wake mode after a stop

    func testSendFromCollectingActsAsStopAndSendThenReturnsToListening() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<1000, text: "hello there", source: .live)]
            ))
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: ledgerBox, sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)

        await store.handle(CommandEvent(kind: .send, atOffset: 1000, confidence: 1))

        XCTAssertEqual(sender.sentTexts, ["stt-rec: hello there"])
        XCTAssertEqual(store.phase, .listening)
        XCTAssertTrue(store.turnRanges.isEmpty)
    }

    func testSendFromListeningSendsThePendingTurnLeftByAnEarlierStop() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<1000, text: "hello there", source: .live)]
            ))
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: ledgerBox, sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)
        await store.handle(CommandEvent(kind: .stop, atOffset: 1000, confidence: 1))
        XCTAssertEqual(store.phase, .listening)

        await store.handle(CommandEvent(kind: .send, atOffset: 1500, confidence: 1))

        XCTAssertEqual(sender.sentTexts, ["stt-rec: hello there"])
        XCTAssertEqual(store.phase, .listening)
        XCTAssertTrue(store.turnRanges.isEmpty)
    }

    func testSendFromListeningWithNothingPendingIsANoOp() async {
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: LedgerBox(emptyLedger()), sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)
        await store.handle(CommandEvent(kind: .stop, atOffset: 0, confidence: 1))  // -> listening, empty turn

        await store.handle(CommandEvent(kind: .send, atOffset: 100, confidence: 1))

        XCTAssertTrue(sender.sentTexts.isEmpty)
        XCTAssertEqual(store.phase, .listening)
    }

    func testSendWithNoCoveredTextAtAllReturnsToListeningWithoutSendingAnEmptyMessage() async {
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: LedgerBox(emptyLedger()), sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)

        await store.handle(CommandEvent(kind: .send, atOffset: 500, confidence: 1))

        XCTAssertTrue(sender.sentTexts.isEmpty)
        XCTAssertEqual(store.phase, .listening)
    }

    // MARK: - Hold while a gap is open, auto-send once it closes

    func testSendWithAnOpenGapHoldsRatherThanSendingHalfTheMessage() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<500, text: "partial", source: .live)],
                gaps: [Gap(range: 500..<1000)]
            ))
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: ledgerBox, sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)

        await store.handle(CommandEvent(kind: .send, atOffset: 1000, confidence: 1))

        XCTAssertTrue(sender.sentTexts.isEmpty)
        XCTAssertEqual(store.phase, .pendingSend)
        XCTAssertEqual(store.turnRanges, [0..<1000])
    }

    func testLedgerChangedSendsTheHeldMessageOnceTheGapCloses() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<500, text: "partial", source: .live)],
                gaps: [Gap(range: 500..<1000)]
            ))
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: ledgerBox, sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)
        await store.handle(CommandEvent(kind: .send, atOffset: 1000, confidence: 1))
        XCTAssertEqual(store.phase, .pendingSend)

        // The backfill closes the gap and adds the rest of the segment.
        ledgerBox.ledger = TranscriptLedger(
            takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
            segments: [
                Segment(range: 0..<500, text: "partial", source: .live),
                Segment(range: 500..<1000, text: "message now complete", source: .batch),
            ], gaps: []
        )
        await store.ledgerChanged()

        XCTAssertEqual(sender.sentTexts, ["stt-rec: partial message now complete"])
        XCTAssertEqual(store.phase, .listening)
        XCTAssertTrue(store.turnRanges.isEmpty)
    }

    func testLedgerChangedIsANoOpWhenNotCurrentlyHoldingATurn() async {
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: LedgerBox(emptyLedger()), sender: sender)
        await store.ledgerChanged()  // Never entered `.pendingSend` — nothing to do.
        XCTAssertTrue(sender.sentTexts.isEmpty)
        XCTAssertEqual(store.phase, .idle)
    }

    // MARK: - Skip

    func testSkipNeverChangesThePhaseItIsSpeechOutputsOwnConcern() async {
        let store = makeStore(ledgerBox: LedgerBox(emptyLedger()), sender: SendRecorder())
        store.startEntering()
        store.finishEntering(atOffset: 0)
        let phaseBefore = store.phase

        await store.handle(CommandEvent(kind: .skip, atOffset: 10, confidence: 1))

        XCTAssertEqual(store.phase, phaseBefore)
    }

    // MARK: - End: leaves call mode, never silently drops a pending turn

    func testEndWithNothingPendingClearsAbandonedText() async {
        let store = makeStore(ledgerBox: LedgerBox(emptyLedger()), sender: SendRecorder())
        store.startEntering()
        store.finishEntering(atOffset: 0)

        await store.handle(CommandEvent(kind: .end, atOffset: 100, confidence: 1))

        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.lastAbandonedTurnText)
    }

    func testEndWithAPendingTurnHandsItsTextToLastAbandonedTurnTextRatherThanSendingOrLosingIt() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<1000, text: "never mind", source: .live)]
            ))
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: ledgerBox, sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)
        await store.handle(CommandEvent(kind: .stop, atOffset: 1000, confidence: 1))
        XCTAssertEqual(store.turnRanges, [0..<1000])

        await store.handle(CommandEvent(kind: .end, atOffset: 1000, confidence: 1))

        XCTAssertTrue(sender.sentTexts.isEmpty, "end never sends — only send does")
        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(store.lastAbandonedTurnText, "stt-rec: never mind")
        XCTAssertTrue(store.turnRanges.isEmpty)
    }

    func testStartEnteringResetsLastAbandonedTurnTextFromAPreviousCall() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<1000, text: "never mind", source: .live)]
            ))
        let store = makeStore(ledgerBox: ledgerBox, sender: SendRecorder())
        store.startEntering()
        store.finishEntering(atOffset: 0)
        await store.handle(CommandEvent(kind: .stop, atOffset: 1000, confidence: 1))
        await store.handle(CommandEvent(kind: .end, atOffset: 1000, confidence: 1))
        XCTAssertNotNil(store.lastAbandonedTurnText)

        store.startEntering()

        XCTAssertNil(store.lastAbandonedTurnText)
    }

    // MARK: - Every accepted command earns its confirmation tone

    func testEveryCommandKindFiresACommandRecognizedFeedbackEvent() async {
        actor Recorder {
            private(set) var kinds: [CommandKind] = []
            func record(_ kind: CommandKind) { kinds.append(kind) }
        }
        let recorder = Recorder()
        let store = makeStore(
            ledgerBox: LedgerBox(emptyLedger()), sender: SendRecorder(),
            feedback: { event in
                if case .commandRecognized(let kind) = event {
                    Task { await recorder.record(kind) }
                }
            })
        store.startEntering()
        store.finishEntering(atOffset: 0)

        for kind in CommandKind.allCases {
            await store.handle(CommandEvent(kind: kind, atOffset: 0, confidence: 1))
        }
        // Yield so the detached recording tasks above actually land before asserting.
        for _ in 0..<100 { await Task.yield() }

        let recorded = await recorder.kinds
        XCTAssertEqual(Set(recorded), Set(CommandKind.allCases))
    }

    // MARK: - Session status refuses sending, never ends the call

    func testATerminalSessionStatusRefusesTheSendButKeepsTheCallInListening() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<1000, text: "hello there", source: .live)]
            ))
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: ledgerBox, sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)
        store.sessionStatusChanged(.completed)

        await store.handle(CommandEvent(kind: .send, atOffset: 1000, confidence: 1))

        XCTAssertTrue(sender.sentTexts.isEmpty, "a terminal session must never receive a new send")
        XCTAssertEqual(store.phase, .listening, "the call itself stays open even when sending is refused")
    }

    func testAnActiveSessionStatusDoesNotRefuseSending() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<1000, text: "hello there", source: .live)]
            ))
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: ledgerBox, sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)
        store.sessionStatusChanged(.active)

        await store.handle(CommandEvent(kind: .send, atOffset: 1000, confidence: 1))

        XCTAssertEqual(sender.sentTexts, ["stt-rec: hello there"])
    }

    // MARK: - A failed send is recorded but never leaves the call stuck

    func testAFailedPostMessageIsRecordedAndTheCallReturnsToListening() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<1000, text: "hello there", source: .live)]
            ))
        let sender = SendRecorder()
        sender.nextFailure = SendFailure()
        let store = makeStore(ledgerBox: ledgerBox, sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)

        await store.handle(CommandEvent(kind: .send, atOffset: 1000, confidence: 1))

        XCTAssertTrue(sender.sentTexts.isEmpty)
        XCTAssertEqual(store.phase, .listening)
        XCTAssertNotNil(store.lastSendFailure)
        XCTAssertEqual(
            store.lastUnsentTurnText, "stt-rec: hello there",
            "a failed postMessage must not silently lose the text it failed to send")
    }

    // MARK: - Refused/failed sends hand their text back rather than losing it

    func testARefusedSendSetsLastUnsentTurnTextRatherThanLosingIt() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<1000, text: "hello there", source: .live)]
            ))
        let store = makeStore(ledgerBox: ledgerBox, sender: SendRecorder())
        store.startEntering()
        store.finishEntering(atOffset: 0)
        store.sessionStatusChanged(.completed)

        await store.handle(CommandEvent(kind: .send, atOffset: 1000, confidence: 1))

        XCTAssertEqual(store.lastUnsentTurnText, "stt-rec: hello there")
    }

    func testConsumeUnsentTurnTextReadsAndClearsItInOneStep() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<1000, text: "hello there", source: .live)]
            ))
        let store = makeStore(ledgerBox: ledgerBox, sender: SendRecorder())
        store.startEntering()
        store.finishEntering(atOffset: 0)
        store.sessionStatusChanged(.completed)
        await store.handle(CommandEvent(kind: .send, atOffset: 1000, confidence: 1))
        XCTAssertNotNil(store.lastUnsentTurnText)

        let consumed = store.consumeUnsentTurnText()

        XCTAssertEqual(consumed, "stt-rec: hello there")
        XCTAssertNil(store.lastUnsentTurnText, "a second read must not hand back the same text again")
    }

    func testASuccessfulSendLeavesNothingInLastUnsentTurnText() async {
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<1000, text: "hello there", source: .live)]
            ))
        let store = makeStore(ledgerBox: ledgerBox, sender: SendRecorder())
        store.startEntering()
        store.finishEntering(atOffset: 0)

        await store.handle(CommandEvent(kind: .send, atOffset: 1000, confidence: 1))

        XCTAssertNil(store.lastUnsentTurnText)
    }

    // MARK: - A "send" command word is stripped from its own turn's text before it is sent

    func testSendCommandWordItselfIsStrippedFromTheTextItTriggeredSending() async {
        let words = [
            Word(range: 0..<400, text: "hello"), Word(range: 400..<700, text: "kai"),
            Word(range: 700..<1000, text: "send"),
        ]
        let ledgerBox = LedgerBox(
            TranscriptLedger(
                takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
                segments: [Segment(range: 0..<1000, text: "hello kai send", words: words, source: .live)]
            ))
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: ledgerBox, sender: sender)
        store.startEntering()
        store.finishEntering(atOffset: 0)

        await store.handle(CommandEvent(kind: .send, atOffset: 850, confidence: 1))

        XCTAssertEqual(
            sender.sentTexts, ["stt-rec: hello"],
            "the command's own spoken words must not land inside the message it sent")
    }

    // MARK: - Crash-cut recovery

    func testRecoverCrashCutAssemblesTheStrandedTextWithoutSendingItAutomatically() {
        let ledger = TranscriptLedger(
            takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
            segments: [
                Segment(range: 0..<500, text: "already sent", source: .live),
                Segment(range: 500..<1200, text: "stranded when the app died", source: .live),
            ],
            boundaries: [
                MessageBoundary(atOffset: 500, kind: .stop, sentMessageId: "msg-1"),
                MessageBoundary(atOffset: 1200, kind: .crashCut),
            ]
        )
        let sender = SendRecorder()
        let store = makeStore(ledgerBox: LedgerBox(ledger), sender: sender)

        let recovered = store.recoverCrashCut(
            boundary: MessageBoundary(atOffset: 1200, kind: .crashCut), ledger: ledger)

        XCTAssertEqual(recovered, "stranded when the app died")
        XCTAssertTrue(sender.sentTexts.isEmpty, "recovered text is never sent automatically")
        XCTAssertEqual(store.phase, .listening)
    }

    func testRecoverCrashCutWithNoPriorBoundaryUsesTheCollectingRangesStart() {
        let ledger = TranscriptLedger(
            takeId: "take-1", mode: .call, sampleRate: 16000, draftKey: "session-1", preText: "",
            segments: [Segment(range: 100..<800, text: "the whole take before it died", source: .live)],
            boundaries: [MessageBoundary(atOffset: 800, kind: .crashCut)],
            collecting: [100..<800]
        )
        let store = makeStore(ledgerBox: LedgerBox(ledger), sender: SendRecorder())

        let recovered = store.recoverCrashCut(
            boundary: MessageBoundary(atOffset: 800, kind: .crashCut), ledger: ledger)

        XCTAssertEqual(recovered, "the whole take before it died")
    }
}
