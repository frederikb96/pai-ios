import XCTest
@testable import PAIKit

final class PaiModelsTests: XCTestCase {

    // MARK: - PaiJSONValue

    /// The whole reason `ToolCall.input` decodes through `[String: PaiJSONValue]` instead of a
    /// keyed container is to avoid a global key-decoding strategy renaming arbitrary tool
    /// arguments. If a future refactor adds `JSONDecoder().keyDecodingStrategy =
    /// .convertFromSnakeCase` anywhere upstream of this decode, `file_path` would silently
    /// become `filePath` and every card built on it would show the wrong key.
    func testToolCallInputPreservesSnakeCaseKeysExactly() throws {
        let json = Data(#"{"id":"t1","name":"Edit","input":{"file_path":"/tmp/x","count":2}}"#.utf8)
        let call = try JSONDecoder().decode(ToolCall.self, from: json)

        guard case let .string(path)? = call.input["file_path"] else {
            return XCTFail("Expected input[\"file_path\"] to survive undisturbed")
        }
        XCTAssertEqual(path, "/tmp/x")
        XCTAssertNil(call.input["filePath"], "must not have been silently renamed")
    }

    func testJSONValueRoundTripsNestedObjectsAndArrays() throws {
        let json = Data(#"{"a":[1,2,{"b":"c"}],"d":null,"e":true}"#.utf8)
        let value = try JSONDecoder().decode(PaiJSONValue.self, from: json)
        let reencoded = try JSONEncoder().encode(value)
        let roundTripped = try JSONDecoder().decode(PaiJSONValue.self, from: reencoded)

        XCTAssertEqual(value, roundTripped)
    }

    // MARK: - TokenUsage

    /// `TokenUsage` intentionally has no `CodingKeys` at all — it decodes the whole object as a
    /// bag so a field Anthropic adds later is kept rather than dropped. This proves both halves:
    /// a named accessor still works, and an unnamed key isn't lost.
    func testTokenUsagePreservesUnknownFieldsAlongsideNamedAccessors() throws {
        let json = Data(#"{"input_tokens":10,"output_tokens":20,"a_future_field":"x"}"#.utf8)
        let usage = try JSONDecoder().decode(TokenUsage.self, from: json)

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.values["a_future_field"], .string("x"))
    }

    // MARK: - Message

    /// One decode exercising every field on `Message`, including its nested types, so a typo'd
    /// `CodingKeys` case anywhere in the struct shows up as a wrong/nil property instead of
    /// passing silently because only a subset of fields was ever fed through a test.
    func testMessageDecodesEveryFieldOntoTheRightProperty() throws {
        let json = Data("""
        {
          "id": 5, "session_id": "s1", "type": "assistant", "subtype": null,
          "timestamp": "2026-08-24T00:00:00Z", "content": "hi", "thinking": "hmm",
          "tool_calls": [{"id":"t1","name":"Bash","input":{"command":"ls"}}],
          "tool_result": {"tool_use_id":"t1","tool_name":"Bash","content":"ok","is_error":false},
          "hook_summary": {"hook_names":["h1"],"has_errors":false,"errors":[],"prevented_continuation":false},
          "tokens": {"input_tokens": 3},
          "created_at": "2026-08-24T00:00:01Z"
        }
        """.utf8)
        let message = try JSONDecoder().decode(Message.self, from: json)

        XCTAssertEqual(message.sessionId, "s1")
        XCTAssertEqual(message.type, .assistant)
        XCTAssertEqual(message.toolCalls?.first?.name, "Bash")
        XCTAssertEqual(message.toolResult?.toolUseId, "t1")
        XCTAssertEqual(message.toolResult?.isError, false)
        XCTAssertEqual(message.hookSummary?.hasErrors, false)
        XCTAssertEqual(message.hookSummary?.preventedContinuation, false)
        XCTAssertEqual(message.tokens?.inputTokens, 3)
        XCTAssertEqual(message.createdAt, "2026-08-24T00:00:01Z")
    }

    func testMessageTypeToolResultUsesSnakeCaseRawValue() throws {
        let json = Data(#""tool_result""#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MessageType.self, from: json), .toolResult)
    }

    // MARK: - Unrecognized enum values

    /// The regression this guards: before `.unrecognized` existed, one session carrying a
    /// status this build predates threw during `[Session].self` decoding — since that decode is
    /// atomic, the *whole list* came back empty instead of the one row degrading.
    func testSessionListSurvivesOneUnrecognizedStatusInsteadOfFailingEntirely() throws {
        let json = Data("""
        [
          {"id":"s1","session_type":"claude","status":"active","state":null,"blocker":null,
           "title":null,"title_locked":null,"initial_message":null,"pending_message":null,
           "session_tokens":0,"claude_session_id":null,"cse_id":null,"created_at":null,
           "updated_at":null,"last_activity_at":null,"working_dir":null},
          {"id":"s2","session_type":"claude","status":"archived","state":null,"blocker":null,
           "title":null,"title_locked":null,"initial_message":null,"pending_message":null,
           "session_tokens":0,"claude_session_id":null,"cse_id":null,"created_at":null,
           "updated_at":null,"last_activity_at":null,"working_dir":null}
        ]
        """.utf8)
        let sessions = try JSONDecoder().decode([Session].self, from: json)

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].status, .active)
        XCTAssertEqual(sessions[1].status, .unrecognized("archived"))
    }

    func testSessionStatusRoundTripsAnUnrecognizedValueRatherThanDroppingIt() throws {
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(#""archived""#.utf8))
        let reencoded = try JSONEncoder().encode(status)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), #""archived""#)
    }

    /// `BlockerKind` already had a bare `unknown` case for the backend's own literal
    /// `"unknown"` value before `.unrecognized` was added — this pins the two stay distinct.
    func testBlockerKindDistinguishesBackendUnknownFromAnUnrecognizedValue() throws {
        XCTAssertEqual(
            try JSONDecoder().decode(BlockerKind.self, from: Data(#""unknown""#.utf8)),
            .unknown
        )
        XCTAssertEqual(
            try JSONDecoder().decode(BlockerKind.self, from: Data(#""future_kind""#.utf8)),
            .unrecognized("future_kind")
        )
    }

    // MARK: - PutDraftResult

    /// The two branches of this union are told apart by a `deleted` flag that is *absent*, not
    /// *false*, on a normal save — a refactor that changes the discriminator to "is `deleted`
    /// present and truthy" vs. "is `deleted` present at all" would misroute a save that happens
    /// to omit the field differently. Both branches are exercised so either mistake shows up.
    func testPutDraftResultDiscriminatesSavedFromDeleted() throws {
        let saved = try JSONDecoder().decode(
            PutDraftResult.self,
            from: Data(#"{"key":"new","text":"hi","session_type":null,"working_dir":null,"updated_at":null}"#.utf8)
        )
        guard case let .saved(draft) = saved else { return XCTFail("Expected .saved") }
        XCTAssertEqual(draft.text, "hi")

        let deleted = try JSONDecoder().decode(
            PutDraftResult.self,
            from: Data(#"{"key":"new","deleted":true}"#.utf8)
        )
        guard case let .deleted(key) = deleted else { return XCTFail("Expected .deleted") }
        XCTAssertEqual(key, "new")
    }

    // MARK: - ClaudeAuth

    /// `known: false` must not decode into the same shape a caller could mistake for "signed
    /// out" — the doc comment on `ClaudeAuth` calls this out as a real UI bug waiting to happen.
    /// The regression this guards is a decode failure or default-substitution that turns an
    /// absent `logged_in` into `false` rather than `nil`.
    func testClaudeAuthUnknownStateKeepsLoggedInNilRatherThanFalse() throws {
        let json = Data(#"{"known": false}"#.utf8)
        let auth = try JSONDecoder().decode(ClaudeAuth.self, from: json)

        XCTAssertFalse(auth.known)
        XCTAssertNil(auth.loggedIn)
    }
}
