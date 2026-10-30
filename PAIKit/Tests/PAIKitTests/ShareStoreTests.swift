import XCTest

@testable import PAIKit

@MainActor
final class ShareStoreTests: XCTestCase {

    private actor FakeBackend: ShareBackend {
        struct Upload: Equatable {
            let key: String
            let id: String
            let filename: String
        }

        var uploads: [Upload] = []
        var queries: [String?] = []
        /// Answers per upload attempt, oldest first; an empty queue means a stored row.
        var answers: [Result<String, PaiError>] = []
        var sessionsAnswer: Result<[Session], PaiError> = .success([])

        func queue(_ answers: [Result<String, PaiError>]) { self.answers = answers }
        func setSessions(_ answer: Result<[Session], PaiError>) { sessionsAnswer = answer }

        func sessionsToShareInto(query: String?) async throws -> [Session] {
            queries.append(query)
            return try sessionsAnswer.get()
        }

        func addDraftAttachment(key: String, file: PaiFileUpload, id: String) async throws -> DraftAttachment {
            uploads.append(Upload(key: key, id: id, filename: file.filename))
            let state = answers.isEmpty ? "stored" : try answers.removeFirst().get()
            let json = """
                { "id": "\(id)", "filename": "\(file.filename)", "path": "/p", "size": 1, "content_type": null,
                  "state": "\(state)", "created_at": "2026-08-29T00:00:00.000000+00:00" }
                """
            return try JSONDecoder().decode(DraftAttachment.self, from: Data(json.utf8))
        }
    }

    private static let noMark = ShareAttemptMark(isSet: { false }, set: { _ in })

    private final class Mark: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        private(set) var writes: [Bool] = []

        init(_ value: Bool) { self.value = value }

        var attemptMark: ShareAttemptMark {
            ShareAttemptMark(
                isSet: { self.lock.withLock { self.value } },
                set: { new in
                    self.lock.withLock {
                        self.value = new
                        self.writes.append(new)
                    }
                })
        }
    }

    /// The mark has to be up while a file is on its way, which is when the system ends a process,
    /// so it is read from inside the upload.
    func testASendThatDiesLeavesItsMarkForTheNextShare() async {
        let mark = Mark(false)
        let probe = ShareItem(id: "x", name: "x") {
            XCTAssertEqual(mark.attemptMark.isSet(), true)
            return PaiFileUpload(filename: "x", mimeType: "text/plain", data: Data())
        }
        let store = ShareStore(items: [probe], refusal: nil, backend: FakeBackend(), attemptMark: mark.attemptMark)
        XCTAssertFalse(store.previousAttemptDied)

        await store.send(to: .newSession)

        XCTAssertEqual(store.phase, .sent(.newSession))
        XCTAssertFalse(mark.attemptMark.isSet())
    }

    func testAMarkLeftBehindIsReportedOnce() {
        let mark = Mark(true)
        let first = ShareStore(items: [], refusal: nil, backend: FakeBackend(), attemptMark: mark.attemptMark)
        let second = ShareStore(items: [], refusal: nil, backend: FakeBackend(), attemptMark: mark.attemptMark)

        XCTAssertTrue(first.previousAttemptDied)
        XCTAssertFalse(second.previousAttemptDied)
    }

    func testAFailedSendClearsItsMark() async {
        let backend = FakeBackend()
        await backend.queue([.failure(.transport("offline"))])
        let mark = Mark(false)
        let store = ShareStore(items: [item("a")], refusal: nil, backend: backend, attemptMark: mark.attemptMark)

        await store.send(to: .newSession)

        XCTAssertFalse(mark.attemptMark.isSet())
    }

    private func item(_ name: String) -> ShareItem {
        ShareItem(id: "id-\(name)", name: name) {
            PaiFileUpload(filename: name, mimeType: "text/plain", data: Data(name.utf8))
        }
    }

    private func session(_ overrides: [String: Any]) throws -> Session {
        let list = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(PaiFixtures.sessions.utf8)) as? [[String: Any]])
        var row = try XCTUnwrap(list.first { $0["kind"] == nil || $0["kind"] as? String == "session" })
        row["parent_session_id"] = NSNull()
        row.merge(overrides) { _, new in new }
        return try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: row))
    }

    func testEachFileLandsOnTheChosenDraftInOrderUnderItsOwnId() async {
        let backend = FakeBackend()
        let store = ShareStore(
            items: [item("a.pdf"), item("b.txt")], refusal: nil, backend: backend, attemptMark: Self.noMark)

        await store.send(to: .session(id: "s1", title: "One"))

        let uploads = await backend.uploads
        XCTAssertEqual(
            uploads,
            [
                .init(key: "s1", id: "id-a.pdf", filename: "a.pdf"),
                .init(key: "s1", id: "id-b.txt", filename: "b.txt"),
            ])
        XCTAssertEqual(store.phase, .sent(.session(id: "s1", title: "One")))
    }

    func testANewSessionUsesTheDraftTheNewSessionScreenReads() async {
        let backend = FakeBackend()
        let store = ShareStore(items: [item("a.pdf")], refusal: nil, backend: backend, attemptMark: Self.noMark)

        await store.send(to: .newSession)

        let keys = await backend.uploads.map(\.key)
        XCTAssertEqual(keys, [DraftKey.newSession])
    }

    /// Three files, because one or two cannot show that the retry resumes at the failed one: the
    /// first must not go again and the last must still go.
    func testARetryResumesAtTheFileThatFailedWithTheSameId() async {
        let backend = FakeBackend()
        await backend.queue([.success("stored"), .failure(.transport("offline"))])
        let store = ShareStore(
            items: [item("a"), item("b"), item("c")], refusal: nil, backend: backend, attemptMark: Self.noMark)

        await store.send(to: .newSession)
        guard case .failed(.newSession, let message) = store.phase else {
            return XCTFail("expected a failure, got \(store.phase)")
        }
        XCTAssertEqual(message, "b: offline")

        await store.send(to: .newSession)

        let ids = await backend.uploads.map(\.id)
        XCTAssertEqual(ids, ["id-a", "id-b", "id-b", "id-c"])
        XCTAssertEqual(store.phase, .sent(.newSession))
    }

    /// The route answers 200 with `failed` when it could not place the file on the machine, so a
    /// good status is not a delivered file.
    func testARowTheServerCouldNotPlaceIsNotDelivered() async {
        let backend = FakeBackend()
        await backend.queue([.success("failed")])
        let store = ShareStore(items: [item("a")], refusal: nil, backend: backend, attemptMark: Self.noMark)

        await store.send(to: .newSession)

        XCTAssertEqual(store.phase, .failed(.newSession, message: "a did not reach the server."))
        await store.send(to: .newSession)
        XCTAssertEqual(store.phase, .sent(.newSession))
    }

    func testARefusedSignInSaysToSignInAgain() async {
        let backend = FakeBackend()
        await backend.queue([.failure(.detail("Invalid token", statusCode: 401))])
        let store = ShareStore(items: [item("a")], refusal: nil, backend: backend, attemptMark: Self.noMark)

        await store.send(to: .newSession)

        XCTAssertEqual(
            store.phase, .failed(.newSession, message: "a: PAI refused the sign-in. Open the app and sign in again."))
    }

    func testAFileThatCannotBeReadUploadsNothing() async {
        struct Unreadable: LocalizedError {
            var errorDescription: String? { "gone" }
        }
        let backend = FakeBackend()
        let bad = ShareItem(id: "x", name: "x") { throw Unreadable() }
        let store = ShareStore(items: [bad, item("after")], refusal: nil, backend: backend, attemptMark: Self.noMark)

        await store.send(to: .newSession)

        XCTAssertEqual(store.phase, .failed(.newSession, message: "x: gone"))
        let uploads = await backend.uploads
        XCTAssertEqual(uploads, [])
    }

    /// A second tap while the first send is running, and one after it finished, are both nothing.
    func testSendingCannotRunTwice() async {
        let backend = FakeBackend()
        let store = ShareStore(items: [item("a")], refusal: nil, backend: backend, attemptMark: Self.noMark)

        async let first: Void = store.send(to: .newSession)
        async let second: Void = store.send(to: .newSession)
        _ = await (first, second)
        await store.send(to: .newSession)

        let count = await backend.uploads.count
        XCTAssertEqual(count, 1)
    }

    func testOnlySessionsAnAttachmentCanReachAreOffered() async throws {
        let backend = FakeBackend()
        let plain = try session(["id": "11111111-1111-1111-1111-111111111111"])
        let excluded = [
            try session(["status": "deleted"]),
            try session(["kind": "subagent"]),
            try session(["kind": "computer"]),
            try session(["kind": "ultrafast"]),
            try session(["parent_session_id": "22222222-2222-2222-2222-222222222222"]),
        ]
        await backend.setSessions(.success([plain] + excluded))
        let store = ShareStore(items: [], refusal: nil, backend: backend, attemptMark: Self.noMark)

        await store.loadSessions(query: "")

        XCTAssertEqual(store.sessions.map(\.id), [plain.id])
    }

    func testASearchSendsItsTrimmedTextAndAnEmptyOneSendsNone() async {
        let backend = FakeBackend()
        let store = ShareStore(items: [], refusal: nil, backend: backend, attemptMark: Self.noMark)

        await store.loadSessions(query: "  notes ")
        await store.loadSessions(query: "   ")

        let queries = await backend.queries
        XCTAssertEqual(queries, ["notes", nil])
    }

    func testAFailedListSaysSoAndThePreviousSessionsStay() async throws {
        let backend = FakeBackend()
        let plain = try session([:])
        await backend.setSessions(.success([plain]))
        let store = ShareStore(items: [], refusal: nil, backend: backend, attemptMark: Self.noMark)
        await store.loadSessions(query: "")

        await backend.setSessions(.failure(.transport("offline")))
        await store.loadSessions(query: "x")

        XCTAssertEqual(store.sessionsError, "offline")
        XCTAssertEqual(store.sessions.count, 1)
    }
}
