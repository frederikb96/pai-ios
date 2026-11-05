import XCTest

@testable import PAIKit

@MainActor
private final class FakeOutput: PlaybackOutput {
    var onTick: (@MainActor () -> Void)?
    var onFinished: (@MainActor () -> Void)?
    var onInterrupted: (@MainActor () -> Void)?
    var positionMs = 0
    var loads: [(bytes: Int, offsetMs: Int, rate: Double)] = []
    var plays = 0
    var pauses = 0
    var cleared = 0
    var lengthMs = 10_000
    var failPlay = false

    func load(_ data: Data, atMs offsetMs: Int, rate: Double) throws -> Int {
        loads.append((data.count, offsetMs, rate))
        positionMs = offsetMs
        return lengthMs
    }
    func play() throws {
        if failPlay { throw PaiError.transport("no audio route") }
        plays += 1
    }
    func pause() { pauses += 1 }
    func seek(toMs offsetMs: Int) { positionMs = offsetMs }
    func setRate(_ rate: Double) {}
    func clear() { cleared += 1 }
}

private actor FakeSource: PlaybackSource {
    var manifests: [Int: PlaybackManifest] = [:]
    var refusals: [Int: PlaybackRefusal] = [:]
    var segmentRefusals: [Int: PlaybackRefusal] = [:]
    var providers: [Int: PlaybackProvider] = [:]
    private(set) var fetched: [String] = []

    func set(manifest: PlaybackManifest, for id: Int) { manifests[id] = manifest }
    func refuse(_ id: Int, _ refusal: PlaybackRefusal) { refusals[id] = refusal }
    func refuseSegment(_ index: Int, _ refusal: PlaybackRefusal) { segmentRefusals[index] = refusal }
    func provider(_ index: Int, _ provider: PlaybackProvider) { providers[index] = provider }

    func getPlaybackManifest(sessionId: String, messageId: Int) async throws -> PlaybackManifest {
        if let refusal = refusals[messageId] { throw refusal }
        return manifests[messageId] ?? playbackManifest(messageId: messageId, estMs: [10_000])
    }

    func fetchPlaybackSegment(sessionId: String, messageId: Int, index: Int) async throws -> PlaybackSegmentAudio {
        fetched.append("\(messageId):\(index)")
        if let refusal = segmentRefusals[index] { throw refusal }
        return PlaybackSegmentAudio(data: Data(repeating: UInt8(index), count: 4), provider: providers[index])
    }
}

@MainActor
final class PlaybackEngineTests: XCTestCase {
    private struct Rig {
        let engine: PlaybackEngine
        let store: PlaybackStore
        let output: FakeOutput
        let source: FakeSource
        let notices: Notices
    }

    @MainActor
    final class Notices {
        var messages: [(String, Bool)] = []
    }

    private func makeRig() -> Rig {
        let store = PlaybackStore(storage: SettingsInMemoryKeyValueStore())
        let output = FakeOutput()
        let source = FakeSource()
        let notices = Notices()
        let engine = PlaybackEngine(store: store, source: source, output: output) { message, warning in
            notices.messages.append((message, warning))
        }
        return Rig(engine: engine, store: store, output: output, source: source, notices: notices)
    }

    func testAReplyStartsOnItsFirstSegmentAndReportsItself() async {
        let rig = makeRig()
        await rig.source.set(manifest: playbackManifest(messageId: 1, estMs: [10_000, 8_000]), for: 1)
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "Hello", user: true)

        XCTAssertEqual(rig.store.current?.status, .playing)
        XCTAssertEqual(rig.store.current?.title, "Hello")
        XCTAssertEqual(rig.output.plays, 1)
        XCTAssertEqual(rig.store.current?.durationMs, 18_000, "10 s measured + 8 s estimated")
    }

    func testTheNextSegmentIsFetchedAheadAndPlaysOnTheEndOfTheCurrentOne() async {
        let rig = makeRig()
        rig.output.lengthMs = 20_000
        await rig.source.set(manifest: playbackManifest(messageId: 1, estMs: [20_000, 20_000]), for: 1)
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "T")
        var fetched = await rig.source.fetched
        XCTAssertEqual(fetched, ["1:0"], "nothing is synthesised before it is about to be heard")

        rig.output.positionMs = 4_000
        rig.output.onTick?()
        try? await Task.sleep(for: .milliseconds(50))
        fetched = await rig.source.fetched
        XCTAssertEqual(fetched, ["1:0"], "16 s left: not yet")

        rig.output.positionMs = 8_000
        rig.output.onTick?()
        try? await Task.sleep(for: .milliseconds(50))
        fetched = await rig.source.fetched
        XCTAssertEqual(fetched, ["1:0", "1:1"], "under 15 s left: the next one")

        rig.output.onFinished?()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(rig.output.loads.count, 2)
        XCTAssertEqual(rig.store.current?.status, .playing)
    }

    func testTheLastSegmentEndingMarksTheReplyHeardAndStartsTheQueue() async {
        let rig = makeRig()
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "One")
        await rig.engine.enqueue(QueuedReply(sessionId: "s1", messageId: 2, title: "Two"))
        XCTAssertEqual(rig.store.queue.map(\.messageId), [2], "behind what plays")

        rig.output.onFinished?()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.store.heard, [1])
        XCTAssertEqual(rig.store.current?.messageId, 2)
        XCTAssertTrue(rig.store.queue.isEmpty)
    }

    func testAReplyWithNothingToReadIsSkippedAndOnlyATapSaysSo() async {
        let rig = makeRig()
        await rig.source.refuse(1, PlaybackRefusal(status: 404, code: nil, message: "none"))
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "Code only", user: true)
        XCTAssertNil(rig.store.current)
        XCTAssertEqual(rig.notices.messages.map(\.0), [PlaybackEngine.nothingToReadNotice])

        let quiet = makeRig()
        await quiet.source.refuse(1, PlaybackRefusal(status: 404, code: nil, message: "none"))
        await quiet.engine.start(sessionId: "s1", messageId: 1, title: "Code only")
        XCTAssertTrue(quiet.notices.messages.isEmpty, "an autoplay arrival stays quiet")
    }

    func testARefusalIsShownAsTheServersSentenceAndPlayTriesAgain() async {
        let rig = makeRig()
        let refusal = PlaybackRefusal(status: 429, code: "playback_cap_reached", message: "The daily limit is reached.")
        await rig.source.refuse(1, refusal)
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "T", user: true)
        XCTAssertEqual(rig.store.current?.status, .error)
        XCTAssertEqual(rig.store.current?.notice, "The daily limit is reached.")
        XCTAssertEqual(rig.notices.messages.last?.0, "The daily limit is reached.")

        await rig.source.clearRefusal(1)
        await rig.engine.play()
        XCTAssertEqual(rig.store.current?.status, .playing)
    }

    func testAPartItsVoiceCouldNotReadIsSkippedWithOneNoticeAndTheReplyPlaysOn() async {
        let rig = makeRig()
        rig.output.lengthMs = 5_000
        await rig.source.set(manifest: playbackManifest(messageId: 1, estMs: [5_000, 5_000, 5_000]), for: 1)
        await rig.source.refuseSegment(
            1, PlaybackRefusal(status: 502, code: "playback_backup_failed", message: "The backup voice failed."))
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "T")

        rig.output.onFinished?()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.store.current?.status, .playing, "the third part plays")
        XCTAssertEqual(rig.output.loads.map(\.bytes), [4, 4])
        XCTAssertEqual(rig.notices.messages.map(\.0), [PlaybackEngine.skippedPartNotice])
        XCTAssertEqual(rig.notices.messages.last?.1, false, "a skipped part is information, not an error")
        let fetched = await rig.source.fetched
        XCTAssertEqual(fetched, ["1:0", "1:1", "1:2"])
    }

    func testAllPartsSkippedFinishesTheReply() async {
        let rig = makeRig()
        rig.output.lengthMs = 5_000
        await rig.source.set(manifest: playbackManifest(messageId: 1, estMs: [5_000, 5_000]), for: 1)
        let failed = PlaybackRefusal(status: 502, code: "playback_synthesis_failed", message: "failed")
        await rig.source.refuseSegment(0, failed)
        await rig.source.refuseSegment(1, failed)
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "T")
        XCTAssertEqual(rig.notices.messages.map(\.0), [PlaybackEngine.skippedPartNotice], "once per reply")
        XCTAssertTrue(rig.store.heard.contains(1))
        XCTAssertNil(rig.store.current, "the player is idle, not stuck in an error")
    }

    func testALimitStopsThePlayerInsteadOfSkipping() async {
        let rig = makeRig()
        rig.output.lengthMs = 5_000
        await rig.source.set(manifest: playbackManifest(messageId: 1, estMs: [5_000, 5_000]), for: 1)
        await rig.source.refuseSegment(
            1, PlaybackRefusal(status: 503, code: "playback_saving_credits", message: "Saving credits."))
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "T")
        rig.output.onFinished?()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.store.current?.status, .error)
        XCTAssertEqual(rig.store.current?.notice, "Saving credits.")
    }

    func testTheBackupVoiceIsAnnouncedOnlyWhenItFollowsAnotherVoice() async {
        let rig = makeRig()
        rig.output.lengthMs = 5_000
        await rig.source.set(manifest: playbackManifest(messageId: 1, estMs: [5_000, 5_000, 5_000]), for: 1)
        await rig.source.provider(0, .elevenlabs)
        await rig.source.provider(1, .openai)
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "T")
        XCTAssertNil(rig.store.current?.voiceNote, "the first voice heard is not a switch")

        rig.output.onFinished?()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.store.current?.voiceNote, PlaybackEngine.backupVoiceNotice)

        await rig.source.provider(2, .openai)
        rig.output.onFinished?()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(rig.store.current?.voiceNote, "gone at the next segment")
    }

    func testBackupVoiceFirstIsNotAnnounced() async {
        let rig = makeRig()
        await rig.source.provider(0, .openai)
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "T")
        XCTAssertNil(rig.store.current?.voiceNote)
    }

    func testPauseAndTheSystemPausingKeepTheReplyAndPlayResumesIt() async {
        let rig = makeRig()
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "T")
        rig.engine.pause()
        XCTAssertEqual(rig.store.current?.status, .paused)

        await rig.engine.play()
        XCTAssertEqual(rig.store.current?.status, .playing)

        rig.output.onInterrupted?()
        XCTAssertEqual(rig.store.current?.status, .paused, "a call or the lock screen paused it")
        await rig.engine.toggle()
        XCTAssertEqual(rig.store.current?.status, .playing)
    }

    func testSeekingIntoAnotherSegmentFetchesOnlyThatOne() async {
        let rig = makeRig()
        rig.output.lengthMs = 10_000
        await rig.source.set(manifest: playbackManifest(messageId: 1, estMs: [10_000, 10_000, 10_000]), for: 1)
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "T")
        await rig.engine.seek(toMs: 25_000)
        let fetched = await rig.source.fetched
        XCTAssertEqual(fetched, ["1:0", "1:2"])
        XCTAssertEqual(rig.output.loads.last?.offsetMs, 5_000)
        XCTAssertEqual(rig.store.current?.positionMs, 25_000)
    }

    func testStoppingLetsGoOfTheReplyAndTheQueue() async {
        let rig = makeRig()
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "T")
        await rig.engine.enqueue(QueuedReply(sessionId: "s1", messageId: 2, title: "U"))
        rig.engine.stop()
        XCTAssertNil(rig.store.current)
        XCTAssertTrue(rig.store.queue.isEmpty)
    }

    func testAnOutputThatCannotPlayIsAnErrorNotASilentReply() async {
        let rig = makeRig()
        rig.output.failPlay = true
        await rig.engine.start(sessionId: "s1", messageId: 1, title: "T", user: true)
        XCTAssertEqual(rig.store.current?.status, .error)
    }

    func testTheSwitchAndTheHeardListSurviveARelaunch() {
        let storage = SettingsInMemoryKeyValueStore()
        let first = PlaybackStore(storage: storage)
        first.enable("s1")
        first.setAutoplay("s1", true)
        first.markHeard(7)
        let second = PlaybackStore(storage: storage)
        XCTAssertEqual(second.modes["s1"], SessionPlayback(autoplay: true))
        XCTAssertEqual(second.heard, [7])
        second.disable("s1")
        XCTAssertNil(PlaybackStore(storage: storage).modes["s1"])
    }
}

extension FakeSource {
    func clearRefusal(_ id: Int) { refusals[id] = nil }
}

final class PlaybackReplyWatcherTests: XCTestCase {
    private func window(hasNewer: Bool = false) -> TranscriptWindow {
        var window = TranscriptWindow()
        window.bootstrapped = true
        window.hasNewer = hasNewer
        return window
    }

    func testHistoryThatLoadsIsNeverReadOutAndLaterRepliesAre() {
        var watcher = PlaybackReplyWatcher()
        let modes = ["s1": SessionPlayback(autoplay: true)]
        let history = [playbackReply(id: 1, content: "old"), playbackReply(id: 2, content: "older")]
        XCTAssertTrue(watcher.arrivals(modes: modes, messages: ["s1": history], windows: ["s1": window()]).isEmpty)

        let arrived =
            history + [playbackReply(id: 3, type: .user, content: "hi"), playbackReply(id: 4, content: "new")]
        let got = watcher.arrivals(modes: modes, messages: ["s1": arrived], windows: ["s1": window()])
        XCTAssertEqual(got.map(\.id), [4])
        XCTAssertTrue(watcher.arrivals(modes: modes, messages: ["s1": arrived], windows: ["s1": window()]).isEmpty)
    }

    func testNothingAutoplaysWithAutoplayOffOrAWindowAwayFromTheLiveEdge() {
        var off = PlaybackReplyWatcher()
        let modes = ["s1": SessionPlayback(autoplay: false)]
        _ = off.arrivals(
            modes: modes, messages: ["s1": [playbackReply(id: 1, content: "a")]], windows: ["s1": window()])
        XCTAssertTrue(
            off.arrivals(
                modes: modes,
                messages: ["s1": [playbackReply(id: 1, content: "a"), playbackReply(id: 2, content: "b")]],
                windows: ["s1": window()]
            ).isEmpty)

        var away = PlaybackReplyWatcher()
        let on = ["s1": SessionPlayback(autoplay: true)]
        _ = away.arrivals(modes: on, messages: ["s1": [playbackReply(id: 1, content: "a")]], windows: ["s1": window()])
        XCTAssertTrue(
            away.arrivals(
                modes: on, messages: ["s1": [playbackReply(id: 1, content: "a"), playbackReply(id: 2, content: "b")]],
                windows: ["s1": window(hasNewer: true)]
            ).isEmpty)
    }

    func testSwitchingTheModeOffForgetsWhereTheSessionWas() {
        var watcher = PlaybackReplyWatcher()
        let on = ["s1": SessionPlayback(autoplay: true)]
        let rows = [playbackReply(id: 1, content: "a"), playbackReply(id: 2, content: "b")]
        _ = watcher.arrivals(modes: on, messages: ["s1": rows], windows: ["s1": window()])
        _ = watcher.arrivals(modes: [:], messages: ["s1": rows], windows: ["s1": window()])
        XCTAssertTrue(
            watcher.arrivals(modes: on, messages: ["s1": rows], windows: ["s1": window()]).isEmpty,
            "a fresh first sight: the baseline again")
    }
}
