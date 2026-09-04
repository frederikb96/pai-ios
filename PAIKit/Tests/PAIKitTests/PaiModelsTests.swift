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
        let json = Data(
            """
            {
              "id": 5, "session_id": "s1", "type": "assistant", "subtype": null,
              "outbox_id": 42,
              "timestamp": "2026-08-24T00:00:00Z", "content": "hi", "thinking": "hmm",
              "tool_calls": [{"id":"t1","name":"Bash","input":{"command":"ls"}}],
              "tool_result": {"tool_use_id":"t1","tool_name":"Bash","content":"ok","is_error":false},
              "hook_summary": {"hook_names":["h1"],"has_errors":false,"errors":[],"prevented_continuation":false},
              "tokens": {"input_tokens": 3},
              "origin": "agent", "origin_meta": {"from": "laptop", "group": "g1"},
              "notification_marker": "pai-notify:abc-123",
              "created_at": "2026-08-24T00:00:01Z"
            }
            """.utf8)
        let message = try JSONDecoder().decode(Message.self, from: json)

        XCTAssertEqual(message.sessionId, "s1")
        XCTAssertEqual(message.type, .assistant)
        XCTAssertEqual(message.outboxId, 42)
        XCTAssertEqual(message.toolCalls?.first?.name, "Bash")
        XCTAssertEqual(message.toolResult?.toolUseId, "t1")
        XCTAssertEqual(message.toolResult?.isError, false)
        XCTAssertEqual(message.hookSummary?.hasErrors, false)
        XCTAssertEqual(message.hookSummary?.preventedContinuation, false)
        XCTAssertEqual(message.tokens?.inputTokens, 3)
        XCTAssertEqual(message.origin, "agent")
        XCTAssertEqual(message.originMeta?["from"], "laptop")
        XCTAssertEqual(message.notificationMarker, "pai-notify:abc-123")
        XCTAssertEqual(message.createdAt, "2026-08-24T00:00:01Z")
    }

    /// Every row ingested before `notification_marker` existed omits the key entirely, not just
    /// sends it as `null` — a synthesized decoder that required the key would fail every one of
    /// them rather than reading an absent value as "not a notification reply".
    func testMessageNotificationMarkerDecodesToNilWhenTheKeyIsAbsent() throws {
        let json = Data(
            """
            {
              "id": 6, "session_id": "s1", "type": "user", "subtype": null,
              "outbox_id": null,
              "timestamp": null, "content": "hi", "thinking": null,
              "tool_calls": null, "tool_result": null, "hook_summary": null, "tokens": null,
              "origin": null, "origin_meta": null,
              "created_at": null
            }
            """.utf8)
        let message = try JSONDecoder().decode(Message.self, from: json)

        XCTAssertNil(message.notificationMarker)
    }

    // MARK: - PaiJSONValue number precision (Decimal, not Double)

    /// The bug row 37 named: an id or count above 2^53 loses precision the moment it passes
    /// through `Double`. `Decimal` decodes straight from the JSON literal's text, so this must
    /// survive exactly rather than landing on the nearest representable `Double`.
    func testToolCallInputPreservesIntegerPrecisionBeyondDoubleSafeRange() throws {
        let json = Data(#"{"id":"t1","name":"Bash","input":{"count":123456789012345678}}"#.utf8)
        let call = try JSONDecoder().decode(ToolCall.self, from: json)

        guard case let .number(count)? = call.input["count"] else {
            return XCTFail("Expected input[\"count\"] to decode as .number")
        }
        XCTAssertEqual(count, Decimal(string: "123456789012345678"))
    }

    /// The other half of the same bug: a whole number must not gain a spurious `.0` when it
    /// round-trips back out — `Decimal` normalizes `100` to `100`, where `Double` would encode
    /// it as `100.0`.
    func testPaiJSONValueRoundTripsWholeNumberWithoutGainingADecimalPoint() throws {
        let value = try JSONDecoder().decode(PaiJSONValue.self, from: Data("100".utf8))
        let reencoded = try JSONEncoder().encode(value)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), "100")
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
        let json = Data(
            """
            [
              {"id":"s1","session_type":"claude","status":"active","state":null,"blocker":null,
               "title":null,"title_locked":null,"initial_message":null,
               "session_tokens":0,"claude_session_id":null,"cse_id":null,"created_at":null,
               "updated_at":null,"last_activity_at":null,"working_dir":null},
              {"id":"s2","session_type":"claude","status":"archived","state":null,"blocker":null,
               "title":null,"title_locked":null,"initial_message":null,
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

    /// `SessionState` is the field that decides whether a session can be typed into at all — and
    /// unlike `SessionStatus`, `SessionKind`, `BlockerKind` and `MessageType`, nothing pinned its
    /// `.unrecognized` fallback: a `state` string this build predates threw during `[Session]`
    /// decoding with no test catching it, which blanks the *entire* session list rather than
    /// degrading the one row carrying it, since `getSessions` decodes the array in one shot.
    func testSessionListSurvivesOneUnrecognizedStateInsteadOfFailingEntirely() throws {
        let json = Data(
            """
            [
              {"id":"s1","session_type":"claude","status":"active","state":"ready","blocker":null,
               "title":null,"title_locked":null,"initial_message":null,
               "session_tokens":0,"claude_session_id":null,"cse_id":null,"created_at":null,
               "updated_at":null,"last_activity_at":null,"working_dir":null},
              {"id":"s2","session_type":"claude","status":"active","state":"orchestrating","blocker":null,
               "title":null,"title_locked":null,"initial_message":null,
               "session_tokens":0,"claude_session_id":null,"cse_id":null,"created_at":null,
               "updated_at":null,"last_activity_at":null,"working_dir":null}
            ]
            """.utf8)
        let sessions = try JSONDecoder().decode([Session].self, from: json)

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].state, .ready)
        XCTAssertEqual(sessions[1].state, .unrecognized("orchestrating"))
    }

    func testSessionStateRoundTripsAnUnrecognizedValueRatherThanDroppingIt() throws {
        let state = try JSONDecoder().decode(SessionState.self, from: Data(#""orchestrating""#.utf8))
        XCTAssertEqual(state, .unrecognized("orchestrating"))
        let reencoded = try JSONEncoder().encode(state)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), #""orchestrating""#)
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

    // MARK: - Session: multi-agent and subagent fields

    /// The trap the contract analysis called out by name: `Session.kind == .subagent` names a
    /// Claude Code sub-conversation, and `agent` (a plain machine-slug `String`) names the
    /// physical box the session runs on — unrelated concepts that a wrong port could conflate.
    /// One decode exercising every field this port adds, so a typo'd `CodingKeys` case among
    /// them shows up as a wrong/nil property rather than passing on a test that only fed a
    /// subset through.
    func testSessionDecodesMultiAgentAndSubagentFieldsOntoTheRightProperty() throws {
        let json = Data(
            """
            {"id":"s1","session_type":"claude","status":"active","state":"ready","blocker":null,
             "working":true,"title":"t","title_locked":true,"initial_message":null,
             "session_tokens":0,"claude_session_id":null,
             "idle_timeout_minutes":30,"effective_idle_timeout_minutes":30,"cse_id":null,
             "created_at":null,"updated_at":null,"last_activity_at":null,"working_dir":null,
             "agent":"laptop","kind":"subagent","parent_session_id":"parent-1",
             "subagent_name":"aria","subagent_type":"general-purpose",
             "subagent_description":"heavy lifting","subagent_model":"sonnet",
             "read_position_message_id":4242,"read_position_offset_px":137,
             "read_position_at_bottom":false,
             "remote_control":true,"discovered":false,
             "project_id":"proj-1","phase_id":"phase-1","project_name":"PAIKit"}
            """.utf8)
        let session = try JSONDecoder().decode(Session.self, from: json)

        XCTAssertEqual(session.working, true)
        XCTAssertEqual(session.idleTimeoutMinutes, 30)
        XCTAssertEqual(session.effectiveIdleTimeoutMinutes, 30)
        XCTAssertEqual(session.agent, "laptop")
        XCTAssertEqual(session.kind, .subagent)
        XCTAssertEqual(session.parentSessionId, "parent-1")
        XCTAssertEqual(session.subagentName, "aria")
        XCTAssertEqual(session.subagentType, "general-purpose")
        XCTAssertEqual(session.subagentDescription, "heavy lifting")
        XCTAssertEqual(session.subagentModel, "sonnet")
        // A mis-keyed CodingKey decodes to nil rather than throwing, so the
        // feature reading these would simply never restore anything and
        // nothing would go red. These assertions are what notices.
        XCTAssertEqual(session.readPositionMessageId, 4242)
        XCTAssertEqual(session.readPositionOffsetPx, 137)
        XCTAssertEqual(session.readPositionAtBottom, false)
        XCTAssertEqual(session.remoteControl, true)
        XCTAssertEqual(session.discovered, false)
        XCTAssertEqual(session.projectId, "proj-1")
        XCTAssertEqual(session.phaseId, "phase-1")
        XCTAssertEqual(session.projectName, "PAIKit")
    }

    /// Same guard as `SessionStatus`: a session list must not go empty just because one row
    /// carries a `kind` this build predates.
    func testSessionKindRoundTripsAnUnrecognizedValueRatherThanDroppingIt() throws {
        let kind = try JSONDecoder().decode(SessionKind.self, from: Data(#""orchestrator""#.utf8))
        XCTAssertEqual(kind, .unrecognized("orchestrator"))
        let reencoded = try JSONEncoder().encode(kind)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), #""orchestrator""#)
    }

    // MARK: - Machine

    func testMachineDecodesNestedCapabilitiesAndSessionTypes() throws {
        let json = Data(
            """
            {"slug":"vm","display_name":"Cloud Kai","online":true,"last_seen_at":null,
             "ingest_enabled":true,
             "capabilities":{"fast_sessions":true,"reboot":false,"shell":true},
             "session_types":[{"id":"fast","name":"Fast","icon":"bolt","working_dir":"/root"}]}
            """.utf8)
        let machine = try JSONDecoder().decode(Machine.self, from: json)

        XCTAssertEqual(machine.id, "vm")
        XCTAssertEqual(machine.displayName, "Cloud Kai")
        XCTAssertEqual(machine.capabilities.fastSessions, true)
        XCTAssertEqual(machine.capabilities.reboot, false)
        XCTAssertEqual(machine.sessionTypes.first?.workingDir, "/root")
    }

    // MARK: - SessionSearchResult

    /// `SessionSearchResult` decodes `Session`'s fields and `score` from the SAME flat JSON
    /// object rather than a nested one (`types.ts` expresses it as a structural extension) — the
    /// regression this guards is that composition mistake silently losing either half.
    func testSessionSearchResultDecodesSessionFieldsAlongsideScore() throws {
        let json = Data(
            """
            {"id":"s1","session_type":"claude","status":"active","state":null,"blocker":null,
             "working":null,"title":"Found me","title_locked":null,"initial_message":null,
             "session_tokens":0,"claude_session_id":null,
             "idle_timeout_minutes":null,"effective_idle_timeout_minutes":null,"cse_id":null,
             "created_at":null,"updated_at":null,"last_activity_at":null,"working_dir":null,
             "agent":null,"kind":null,"parent_session_id":null,"subagent_name":null,
             "subagent_type":null,"subagent_description":null,"remote_control":null,
             "discovered":null,"project_id":null,"phase_id":null,"project_name":null,
             "score":0.8421}
            """.utf8)
        let result = try JSONDecoder().decode(SessionSearchResult.self, from: json)

        XCTAssertEqual(result.session.title, "Found me")
        XCTAssertEqual(result.score, 0.8421)

        let reencoded = try JSONEncoder().encode(result)
        let roundTripped = try JSONDecoder().decode(SessionSearchResult.self, from: reencoded)
        XCTAssertEqual(roundTripped, result)
    }

    /// A fuzzy hit's `score` is `null`, not absent — distinct from a semantic hit's `0...1`.
    func testSessionSearchResultDecodesNullScoreForAFuzzyHit() throws {
        let json = Data(
            """
            {"id":"s1","session_type":"claude","status":"active","state":null,"blocker":null,
             "working":null,"title":null,"title_locked":null,"initial_message":null,
             "session_tokens":0,"claude_session_id":null,
             "idle_timeout_minutes":null,"effective_idle_timeout_minutes":null,"cse_id":null,
             "created_at":null,"updated_at":null,"last_activity_at":null,"working_dir":null,
             "agent":null,"kind":null,"parent_session_id":null,"subagent_name":null,
             "subagent_type":null,"subagent_description":null,"remote_control":null,
             "discovered":null,"project_id":null,"phase_id":null,"project_name":null,
             "score":null}
            """.utf8)
        let result = try JSONDecoder().decode(SessionSearchResult.self, from: json)
        XCTAssertNil(result.score)
    }

    // MARK: - ResumeResponse

    func testResumeResponseDecodesEmbeddedSessionWhenPresent() throws {
        let json = Data(
            """
            {"status":"resumed",
             "session":{"id":"s1","session_type":"claude","status":"active","state":"ready",
              "blocker":null,"working":null,"title":null,"title_locked":null,
              "initial_message":null,"session_tokens":0,
              "claude_session_id":null,"idle_timeout_minutes":null,
              "effective_idle_timeout_minutes":null,"cse_id":null,"created_at":null,
              "updated_at":null,"last_activity_at":null,"working_dir":null,"agent":null,
              "kind":null,"parent_session_id":null,"subagent_name":null,"subagent_type":null,
              "subagent_description":null,"remote_control":null,"discovered":null,
              "project_id":null,"phase_id":null,"project_name":null}}
            """.utf8)
        let response = try JSONDecoder().decode(ResumeResponse.self, from: json)

        XCTAssertEqual(response.status, .resumed)
        XCTAssertEqual(response.session?.state, .ready)
    }

    func testResumeResponseSessionIsAbsentFromAnOlderBackend() throws {
        let response = try JSONDecoder().decode(ResumeResponse.self, from: Data(#"{"status":"refused"}"#.utf8))
        XCTAssertNil(response.session)
    }

    // MARK: - SecretStatusMap

    /// Named fields, not a `[String: SecretStatus]` dictionary — see the type's doc comment for
    /// why. This proves the two allowlisted names route to the right property rather than being
    /// silently dropped by a dictionary decode that doesn't match the JSON shape at all.
    func testSecretStatusMapRoutesEachAllowlistedNameToItsOwnField() throws {
        let json = Data(
            #"{"elevenlabs":{"set":true,"updated_at":"2026-08-24T00:00:00Z"}}"#.utf8
        )
        let map = try JSONDecoder().decode(SecretStatusMap.self, from: json)

        XCTAssertEqual(map.elevenlabs?.set, true)
        XCTAssertNil(map.smtpPassword, "absent from the response, must not default to some placeholder")
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

    /// A refused credential must arrive as `loggedIn == false` even though every timestamp in
    /// the payload looks healthy — that combination is the whole outage this state was added
    /// for, and a client that reads the expiries instead sees nothing wrong with it.
    func testClaudeAuthRejectedIsNotLoggedInDespiteHealthyExpiries() throws {
        let auth = try JSONDecoder().decode(
            ClaudeAuth.self, from: Data(PaiFixtures.claudeAuthRejected.utf8),
        )

        XCTAssertEqual(auth.loggedIn, false)
        XCTAssertEqual(auth.health, .rejected)
        XCTAssertNotNil(auth.rejectedSince)
        // Present, in the future, and completely beside the point.
        XCTAssertNotNil(auth.refreshExpiresAt)
    }

    /// A health value this build has never heard of must not fail the decode of a snapshot the
    /// sign-in UI needs — the same reasoning `BlockerKind.unrecognized` exists for.
    func testClaudeAuthKeepsAnUnknownHealthRatherThanFailingTheWholeSnapshot() throws {
        let json = Data(#"{"known": true, "logged_in": false, "health": "quarantined"}"#.utf8)
        let auth = try JSONDecoder().decode(ClaudeAuth.self, from: json)

        XCTAssertEqual(auth.loggedIn, false)
        XCTAssertEqual(auth.health, .unrecognized("quarantined"))
    }

    // MARK: - UserRole

    /// The backend removed guest access; `UserRole` carries only `.owner` now — this pins that a
    /// value from before that removal (or any other unexpected role) genuinely fails the decode
    /// rather than silently degrading, since a wrong guess about who is looking at the app is a
    /// security-relevant one to get loudly wrong.
    func testMeResponseThrowsOnAnUnrecognizedRoleRatherThanGuessing() throws {
        let json = Data(#"{"identity":"freddy","role":"guest","allowed_session_ids":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MeResponse.self, from: json))
    }
}
