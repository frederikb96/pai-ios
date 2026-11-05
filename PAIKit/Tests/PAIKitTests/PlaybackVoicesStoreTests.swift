import XCTest

@testable import PAIKit

private actor FakeVoicesApi: PlaybackVoicesApiClient {
    var list: PlaybackVoices? = try? JSONDecoder().decode(
        PlaybackVoices.self, from: Data(PaiFixtures.playbackVoices.utf8))
    var sampleError: Error?
    private(set) var sampled: [String] = []

    func fail(sample error: Error?) { sampleError = error }
    func breakList() { list = nil }

    func getPlaybackVoices() async throws -> PlaybackVoices {
        guard let list else { throw PaiError.transport("offline") }
        return list
    }

    func fetchPlaybackVoiceSample(provider: PlaybackProvider, voiceId: String) async throws -> Data {
        sampled.append("\(provider.rawValue):\(voiceId)")
        if let sampleError { throw sampleError }
        return Data([1, 2, 3])
    }
}

@MainActor
private final class FakeSamplePlayer: VoiceSamplePlayer {
    var onFinished: (@MainActor () -> Void)?
    var played: [Data] = []
    var stops = 0
    func play(_ data: Data) throws { played.append(data) }
    func stop() { stops += 1 }
}

@MainActor
final class PlaybackVoicesStoreTests: XCTestCase {
    private func makeStore() -> (PlaybackVoicesStore, FakeVoicesApi, FakeSamplePlayer) {
        let api = FakeVoicesApi()
        let player = FakeSamplePlayer()
        let store = PlaybackVoicesStore(api: api)
        store.player = player
        return (store, api, player)
    }

    func testTheListLoadsAndAFailedLoadSaysSo() async {
        let (store, api, _) = makeStore()
        await store.load()
        XCTAssertEqual(store.voices?.elevenlabs.count, 3)
        XCTAssertNil(store.loadError)

        await api.breakList()
        await store.load()
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.voices?.elevenlabs.count, 3, "the last list stays on screen")
    }

    func testTryPlaysThePickedVoiceAndNoneMeansTheDefault() async {
        let (store, api, player) = makeStore()
        await store.load()
        await store.tryVoice("nztoarMvjgs3c0c5DINJ")
        XCTAssertEqual(store.sampleState, .playing)
        XCTAssertEqual(player.played, [Data([1, 2, 3])])

        player.onFinished?()
        XCTAssertEqual(store.sampleState, .idle)

        await store.tryVoice(nil)
        let sampled = await api.sampled
        XCTAssertEqual(sampled, ["elevenlabs:nztoarMvjgs3c0c5DINJ", "elevenlabs:JBFqnCBsd6RMkjVDRZzb"])
    }

    func testPressingTryWhilePlayingStopsTheSample() async {
        let (store, _, player) = makeStore()
        await store.load()
        await store.tryVoice("v1")
        await store.tryVoice("v1")
        XCTAssertEqual(store.sampleState, .idle)
        XCTAssertEqual(player.stops, 1)
        XCTAssertEqual(player.played.count, 1)
    }

    func testARefusedSampleShowsTheServersSentence() async {
        let (store, api, player) = makeStore()
        await api.fail(
            sample: PlaybackRefusal(status: 404, code: nil, message: "This voice has no preview"))
        await store.tryVoice("v1")
        XCTAssertEqual(store.sampleState, .idle)
        XCTAssertEqual(store.sampleError, "This voice has no preview")
        XCTAssertTrue(player.played.isEmpty)

        await api.fail(sample: nil)
        await store.tryVoice("v1")
        XCTAssertNil(store.sampleError, "a new try clears the last message")
    }
}
