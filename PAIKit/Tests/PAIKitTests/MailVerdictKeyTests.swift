import XCTest

@testable import PAIKit

/// The MailVerdict key travels as one header on a message to an assistant session, read at send
/// time, and nowhere else: not on any other message, not in the queued entry.
@MainActor
final class MailVerdictKeyTests: XCTestCase {
    private func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", deviceName: "Test iPhone", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    private func stubCreated() {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"session_id":"s1","message_id":1,"duplicate":false,"draft_version":1}"#.utf8))
    }

    func testTheClientSendsTheKeyHeaderOnlyWhenGivenOne() async throws {
        stubCreated()
        let client = try makeClient()
        _ = try await client.postMessage(
            sessionId: nil, message: "hi", clientMessageId: "c1", files: [], draftAttachmentIds: [],
            supersededUploadIds: [], sessionType: "mailverdict", workingDir: nil, agent: nil, model: nil,
            thinking: nil, clientMode: nil, heldTake: nil, noMemory: nil, mailVerdictKey: "device-key")
        XCTAssertEqual(
            PaiStubURLProtocol.capturedRequest?.value(forHTTPHeaderField: PaiApiClient.mailVerdictKeyHeader),
            "device-key")

        _ = try await client.postMessage(message: "hi", sessionType: "home")
        XCTAssertNil(PaiStubURLProtocol.capturedRequest?.value(forHTTPHeaderField: PaiApiClient.mailVerdictKeyHeader))
    }

    func testOnlyAMessageToAnAssistantSessionCarriesTheKey() async {
        let sender = KeyRecordingSender()
        let store = OutboxStore(api: sender, storage: OutboxInMemoryStorage())
        store.mailVerdictKey = { "device-key" }
        store.isMailVerdictSession = { $0 == "assistant-session" }

        store.enqueue(
            OutboxEntry(
                target: .newSession(
                    agent: nil, sessionType: "mailverdict", workingDir: nil, model: nil, thinking: nil),
                text: "new assistant"))
        store.enqueue(OutboxEntry(target: .session(sessionId: "assistant-session"), text: "follow-up"))
        store.enqueue(OutboxEntry(target: .session(sessionId: "other-session"), text: "plain"))
        store.enqueue(
            OutboxEntry(
                target: .newSession(agent: nil, sessionType: "home", workingDir: nil, model: nil, thinking: nil),
                text: "new home"))

        for _ in 0..<400 where sender.calls.count < 4 { await Task.yield() }
        let byText = Dictionary(uniqueKeysWithValues: sender.calls.map { ($0.message, $0.key) })
        XCTAssertEqual(byText["new assistant"], .some("device-key"))
        XCTAssertEqual(byText["follow-up"], .some("device-key"))
        XCTAssertEqual(byText["plain"], .some(nil))
        XCTAssertEqual(byText["new home"], .some(nil))
    }

    func testTheQueuedEntryNeverHoldsTheKey() async throws {
        let storage = OutboxInMemoryStorage()
        let store = OutboxStore(api: KeyRecordingSender(), storage: storage)
        store.mailVerdictKey = { "device-key-secret" }
        store.enqueue(
            OutboxEntry(
                target: .newSession(
                    agent: nil, sessionType: "mailverdict", workingDir: nil, model: nil, thinking: nil),
                text: "hello"))
        let persisted = try JSONEncoder().encode(storage.loadEntries())
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("device-key-secret"))
    }
}

private final class KeyRecordingSender: OutboxKeyedSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(message: String, key: String?)] = []
    var calls: [(message: String, key: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    private func record(_ message: String, _ key: String?) {
        lock.lock()
        _calls.append((message, key))
        lock.unlock()
    }

    func postMessage(
        sessionId: String?, message: String, clientMessageId: String, files: [PaiFileUpload],
        draftAttachmentIds: [String], supersededUploadIds: [String], sessionType: String?, workingDir: String?,
        agent: String?, model: String?, thinking: String?, clientMode: String?, heldTake: HeldTake?, noMemory: Bool?
    ) async throws -> PostMessageResponse {
        record(message, nil)
        return PostMessageResponse(sessionId: sessionId ?? "new", messageId: 1)
    }

    func postMessage(
        sessionId: String?, message: String, clientMessageId: String, files: [PaiFileUpload],
        draftAttachmentIds: [String], supersededUploadIds: [String], sessionType: String?, workingDir: String?,
        agent: String?, model: String?, thinking: String?, clientMode: String?, heldTake: HeldTake?, noMemory: Bool?,
        mailVerdictKey: String?
    ) async throws -> PostMessageResponse {
        record(message, mailVerdictKey)
        return PostMessageResponse(sessionId: sessionId ?? "new", messageId: 1)
    }
}
