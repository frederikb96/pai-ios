import XCTest

@testable import PAIKit

/// These do not decode fixtures into `Session`/`Message` — those types are mid-rewrite against
/// the same contract this file mirrors, and coupling to them here would break on either side
/// moving for reasons unrelated to whether the JSON itself is right. What is checked instead is
/// the property that actually matters for a corpus whose whole point is exhaustive coverage:
/// every state, blocker kind, message type, subtype and tool family this app has to render is
/// still present after whatever the next edit to a fixture file was. Losing one silently — a
/// session accidentally dropped while tidying up a diff, a subtype typo'd — is exactly the kind
/// of change these are written to catch; a plain JSON-parses check would not.
final class PaiFixturesTests: XCTestCase {

    // MARK: - Helpers

    private func jsonObject(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Any {
        do {
            return try JSONSerialization.jsonObject(with: PaiFixtures.data(text), options: [.fragmentsAllowed])
        } catch {
            XCTFail("not valid JSON: \(error)", file: file, line: line)
            return NSNull()
        }
    }

    private func jsonArray(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [[String: Any]] {
        guard let array = jsonObject(text, file: file, line: line) as? [[String: Any]] else {
            XCTFail("expected a JSON array of objects", file: file, line: line)
            return []
        }
        return array
    }

    private func jsonDict(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard let dict = jsonObject(text, file: file, line: line) as? [String: Any] else {
            XCTFail("expected a JSON object", file: file, line: line)
            return [:]
        }
        return dict
    }

    /// `JSONSerialization` decodes a JSON `null` as `NSNull()`, not Swift `nil` — a dictionary
    /// subscript on a present-but-null key returns `.some(NSNull())`, which `== nil` never
    /// matches. Every "is this field absent-or-null" check below goes through this.
    private func isNullOrMissing(_ value: Any?) -> Bool {
        guard let value else { return true }
        return value is NSNull
    }

    // MARK: - Every fixture is syntactically valid JSON

    /// The cheapest possible regression guard on ~30 hand-typed multiline literals: a dropped
    /// comma or an unbalanced brace in any one of them fails here instead of at the first place
    /// that tries to decode it — which, for most of these, is a metered `Mac` run.
    func testEveryFixtureParsesAsJSON() {
        let arrays: [String] = [
            PaiFixtures.agents, PaiFixtures.sessionTypes, PaiFixtures.sessions,
            PaiFixtures.sessionSearchResults, PaiFixtures.transcript, PaiFixtures.folderFavorites,
            PaiFixtures.emptySessions, PaiFixtures.emptyMessages, PaiFixtures.emptyDrafts,
            PaiFixtures.emptyAgents, PaiFixtures.emptySearchResults, PaiFixtures.drafts,
            PaiFixtures.recordings,
        ]
        for json in arrays { _ = jsonArray(json) }

        let objects: [String] = [
            PaiFixtures.me, PaiFixtures.healthOk, PaiFixtures.healthDegraded, PaiFixtures.usage,
            PaiFixtures.usageEmpty, PaiFixtures.secretStatuses, PaiFixtures.voiceToken,
            PaiFixtures.claudeAuthHealthy, PaiFixtures.claudeAuthUnknown, PaiFixtures.claudeAuthSignedOut,
            PaiFixtures.claudeAuthLoginInProgress, PaiFixtures.recordingClean, PaiFixtures.recordingDegraded,
            PaiFixtures.browseResult, PaiFixtures.outgoingPutDraftNew, PaiFixtures.outgoingPutDraftSession,
            PaiFixtures.outgoingPostMessageNewSession, PaiFixtures.outgoingPostMessageExistingSession,
            PaiFixtures.outgoingRenameSession, PaiFixtures.outgoingSetTitleLocked,
            PaiFixtures.outgoingAnswerBlocker, PaiFixtures.outgoingAddFavorite,
            PaiFixtures.outgoingMintVoiceToken, PaiFixtures.errorSessionNotActive,
            PaiFixtures.errorNonJsonFallback, PaiFixtures.cancelResponse, PaiFixtures.closeResponseError,
            PaiFixtures.closeResponseAlreadyClosed, PaiFixtures.deleteResponseAlreadyDeleted,
            PaiFixtures.resumeResponseRefused, PaiFixtures.answerBlockerNoBlocker,
        ]
        for json in objects { _ = jsonDict(json) }

        for frame in PaiFixtures.terminalFrames { _ = jsonDict(frame) }
    }

    // MARK: - Sessions

    /// The corpus exists to show every `SessionState` at once. Losing one is silent — the app
    /// still renders four states correctly and nobody notices the fifth was never on screen.
    func testSessionsCoverEveryState() {
        let states = Set(jsonArray(PaiFixtures.sessions).compactMap { $0["state"] as? String })
        XCTAssertEqual(states, ["starting", "ready", "blocked", "attention", "closed"])
    }

    /// Same argument for `BlockerKind` — `sessionBlockedTrust` isn't in the main list (it is its
    /// own constant, exercised on its own), so it is added back in here explicitly.
    func testBlockersCoverEveryKind() {
        var kinds = Set(
            jsonArray(PaiFixtures.sessions).compactMap { session in
                (session["blocker"] as? [String: Any])?["kind"] as? String
            })
        kinds.insert((jsonDict(PaiFixtures.sessionBlockedTrust)["blocker"] as? [String: Any])?["kind"] as? String ?? "")

        XCTAssertEqual(
            kinds,
            [
                "trust_prompt", "trust_prompt_confirmed", "login_required", "permission_prompt", "choice_prompt",
                "unknown", "not_registered",
            ],
            "\(kinds)"
        )
    }

    func testChoicePromptBlockerCarriesMultipleOptions() {
        let session = jsonDict(PaiFixtures.sessionBlockedChoice)
        let options = (session["blocker"] as? [String: Any])?["options"] as? [[String: Any]]
        XCTAssertEqual(options?.count, 3)
    }

    /// `login_required` and `not_registered` both carry no options — pressing a key would race
    /// the account-level flow or reach nothing at all, per `docs/ARCHITECTURE.md` "Blockers".
    func testLoginRequiredAndNotRegisteredCarryNoOptions() {
        for session in [PaiFixtures.sessionBlockedLogin, PaiFixtures.sessionAttentionNotRegistered] {
            let options = (jsonDict(session)["blocker"] as? [String: Any])?["options"] as? [[String: Any]]
            XCTAssertEqual(options?.count, 0)
        }
    }

    func testSessionsIncludeBothMachines() {
        let agents = Set(jsonArray(PaiFixtures.sessions).compactMap { $0["agent"] as? String })
        XCTAssertEqual(agents, ["vm", "laptop"])
    }

    /// The subagent is never in the main page (per `docs/ARCHITECTURE.md`, subagents never
    /// appear as top-level rows) but must still reference a real parent, or a session-detail
    /// screen resolving it renders a dangling reference.
    func testSubagentParentExistsAmongTopLevelSessions() {
        let subagent = jsonDict(PaiFixtures.sessionSubagent)
        XCTAssertEqual(subagent["kind"] as? String, "subagent")
        let parentId = subagent["parent_session_id"] as? String
        let topLevelIds = Set(jsonArray(PaiFixtures.sessions).compactMap { $0["id"] as? String })
        XCTAssertNotNil(parentId)
        XCTAssertTrue(topLevelIds.contains(parentId ?? ""), "subagent's parent isn't in the session list")
    }

    /// The whole point of this fixture: a row from before its first agent round-trip has no
    /// `state`/`blocker` key at all — not `null`. A well-meaning edit that adds a default value
    /// would silently defeat the one thing this fixture exists to represent.
    func testMinimalDiscoveredSessionOmitsStateAndBlockerKeysEntirely() {
        let keys = Set(jsonDict(PaiFixtures.sessionMinimalDiscovered).keys)
        XCTAssertFalse(keys.contains("state"))
        XCTAssertFalse(keys.contains("blocker"))
        XCTAssertFalse(keys.contains("working"))
    }

    /// `docs/ARCHITECTURE.md`: `discovered && remote_control` both true is the combination that
    /// needs a confirm step before resuming.
    func testMinimalDiscoveredSessionIsDiscoveredAndRemoteControlled() {
        let session = jsonDict(PaiFixtures.sessionMinimalDiscovered)
        XCTAssertEqual(session["discovered"] as? Bool, true)
        XCTAssertEqual(session["remote_control"] as? Bool, true)
    }

    /// `Agent.backfill` isn't declared on `types.ts`'s `Agent` interface at all, though the
    /// backend sends it (`api.py`'s `backfill_snapshot()`). Documented in
    /// `PaiFixtures+Sessions.swift`; this pins the asymmetry the comment describes so it isn't
    /// quietly "fixed" into symmetry by a future edit.
    func testAgentsBackfillFieldPresentOnVmAbsentOnLaptop() {
        let agents = jsonArray(PaiFixtures.agents)
        let vm = agents.first { $0["slug"] as? String == "vm" }
        let laptop = agents.first { $0["slug"] as? String == "laptop" }
        XCTAssertTrue(vm?.keys.contains("backfill") ?? false)
        XCTAssertFalse(laptop?.keys.contains("backfill") ?? true)
    }

    // MARK: - Transcript

    func testTranscriptCoversEveryMessageType() {
        let types = Set(jsonArray(PaiFixtures.transcript).compactMap { $0["type"] as? String })
        XCTAssertEqual(types, ["user", "assistant", "tool_result", "system"])
    }

    /// The 12 subtypes `systemLabel()` (`messageDisplay.ts`) names explicitly, plus `thinking`
    /// covered separately since it isn't a `subtype` at all (see
    /// ``testTranscriptHasAThinkingOnlyAssistantMessage``).
    func testTranscriptCoversEverySystemSubtype() {
        let subtypes = Set(
            jsonArray(PaiFixtures.transcript)
                .filter { $0["type"] as? String == "system" }
                .compactMap { $0["subtype"] as? String })
        XCTAssertEqual(
            subtypes,
            [
                "skill", "context", "command_output", "image", "compact", "compact_summary",
                "hook", "duration", "interrupt", "notification", "scheduled",
            ])
    }

    /// A relayed prompt is `type: "user"`, not `type: "system"` — the parser emits it that way
    /// and the web intercepts it ahead of the generic system card. `systemLabel()` carries an
    /// entry for it too, which is a defensive label rather than evidence of its type, and reading
    /// that map as the source is how it ends up filed under machinery instead of as a real
    /// message someone sent.
    func testTranscriptHasARelayedPromptTypedAsAUserMessage() {
        let relayed = jsonArray(PaiFixtures.transcript)
            .filter { $0["subtype"] as? String == "pai_message" }
        XCTAssertEqual(relayed.count, 1)
        XCTAssertEqual(relayed.first?["type"] as? String, "user")
    }

    /// The two "permanent legacy row" shapes `messageDisplay.ts` still guards against — content
    /// nobody re-parses, so a renderer that stops handling either shows raw XML/wrapper tags as
    /// if Freddy had typed them.
    func testTranscriptCoversBothLegacyRowShapes() {
        let messages = jsonArray(PaiFixtures.transcript)

        let unparsedCommandXml = messages.first {
            $0["subtype"] as? String == "command" && ($0["content"] as? String)?.hasPrefix("<") == true
        }
        XCTAssertNotNil(unparsedCommandXml, "missing a subtype=command row with unparsed <command-name> XML")

        let localCommandRegex = try! NSRegularExpression(pattern: #"^<local-command-(\w+)>[\s\S]*</local-command-\1>$"#)
        func matchesLegacyLocalCommand(_ content: String, kind: String) -> Bool {
            guard content.hasPrefix("<local-command-\(kind)>") else { return false }
            let range = NSRange(content.startIndex..., in: content)
            return localCommandRegex.firstMatch(in: content, range: range) != nil
        }

        let legacyRows = messages.filter {
            isNullOrMissing($0["subtype"]) && ($0["content"] as? String)?.hasPrefix("<local-command-") == true
        }
        XCTAssertTrue(
            legacyRows.contains { matchesLegacyLocalCommand($0["content"] as! String, kind: "caveat") },
            "missing the 'caveat' legacy row, which must render as nothing"
        )
        XCTAssertTrue(
            legacyRows.contains { matchesLegacyLocalCommand($0["content"] as! String, kind: "stdout") },
            "missing the 'stdout' legacy row, which must render as a SystemCard"
        )
    }

    /// The well-formed sibling of the row above — `"{name}\n\n{args}"`, what `parser.py`
    /// actually produces today, so `CommandCard`'s normal path is exercised too.
    func testTranscriptHasAWellFormedCommandRow() {
        let wellFormed = jsonArray(PaiFixtures.transcript).first {
            $0["subtype"] as? String == "command" && ($0["content"] as? String)?.hasPrefix("<") != true
        }
        XCTAssertNotNil(wellFormed)
        XCTAssertTrue((wellFormed?["content"] as? String)?.contains("\n\n") ?? false)
    }

    func testTranscriptHasAnAgentMessageWithOriginMetadata() {
        let agentMessage = jsonArray(PaiFixtures.transcript).first { $0["subtype"] as? String == "agent_message" }
        XCTAssertEqual(agentMessage?["origin"] as? String, "agent")
        let meta = agentMessage?["origin_meta"] as? [String: String]
        XCTAssertEqual(meta?["from"], "aria")
    }

    /// `getDisplayMessages` (`messages.ts`) drops an assistant entry with no content, no tool
    /// calls and no thinking — this row is what a store built from this fixture has to filter.
    func testTranscriptHasAnEmptyAssistantMessageToDrop() {
        let hasEmptyAssistant = jsonArray(PaiFixtures.transcript).contains {
            $0["type"] as? String == "assistant" && ($0["content"] as? String) == ""
                && isNullOrMissing($0["tool_calls"]) && isNullOrMissing($0["thinking"])
        }
        XCTAssertTrue(hasEmptyAssistant)
    }

    func testTranscriptHasAThinkingOnlyAssistantMessage() {
        let hasThinkingOnly = jsonArray(PaiFixtures.transcript).contains {
            ($0["thinking"] as? String)?.isEmpty == false && isNullOrMissing($0["content"])
                && isNullOrMissing($0["tool_calls"])
        }
        XCTAssertTrue(hasThinkingOnly)
    }

    /// The same nine tool families `toolIcon`/`getToolExpandKey` switch on
    /// (`MessageBubble.tsx`), plus a real `mcp__`-prefixed name.
    func testTranscriptToolCallsCoverEveryToolFamily() {
        let toolCalls = jsonArray(PaiFixtures.transcript).flatMap { $0["tool_calls"] as? [[String: Any]] ?? [] }
        let names = Set(toolCalls.compactMap { $0["name"] as? String })

        for expected in [
            "Bash", "Read", "Edit", "Write", "MultiEdit", "Grep", "Glob", "Task", "WebSearch", "WebFetch", "Skill",
        ] {
            XCTAssertTrue(names.contains(expected), "missing a \(expected) tool call")
        }
        XCTAssertTrue(names.contains { $0.hasPrefix("mcp__") }, "missing an mcp__-prefixed tool call")
    }

    /// Tool calls and tool results are never paired in the data (each `tool_result` message is
    /// its own row) — this proves every call's id is answered by a *separate* result row rather
    /// than by anything carried on the call itself, which is the natural first (wrong) instinct
    /// when modelling this as a Swift type.
    func testEveryToolCallHasASeparateToolResultRowSharingItsId() {
        let messages = jsonArray(PaiFixtures.transcript)
        let callIds = Set(
            messages.flatMap { $0["tool_calls"] as? [[String: Any]] ?? [] }
                .compactMap { $0["id"] as? String })
        let resultIds = Set(
            messages.compactMap { $0["tool_result"] as? [String: Any] }
                .compactMap { $0["tool_use_id"] as? String })

        XCTAssertFalse(callIds.isEmpty)
        XCTAssertEqual(callIds, resultIds, "every tool call id must be answered by exactly one tool_result row")
    }

    func testTranscriptHasBothSuccessfulAndErroredToolResults() {
        let isErrors = Set(
            jsonArray(PaiFixtures.transcript)
                .compactMap { $0["tool_result"] as? [String: Any] }
                .compactMap { $0["is_error"] as? Bool })
        XCTAssertEqual(isErrors, [true, false])
    }

    /// The markdown edge cases that stress the renderer, all inside this one transcript: a GFM
    /// table, a syntax-highlighted code fence, nested lists, a very long bare URL, a blockquote
    /// and inline code.
    func testTranscriptMarkdownCoversEveryStressCase() {
        let bodies = jsonArray(PaiFixtures.transcript).compactMap { $0["content"] as? String }
        let all = bodies.joined(separator: "\n---\n")

        XCTAssertTrue(all.contains("| Model | Input | Output |"), "no GFM table")
        XCTAssertTrue(all.contains("```swift"), "no fenced, language-tagged code block")
        XCTAssertTrue(all.contains("  - vm\n"), "no nested (level-2) list item")
        XCTAssertTrue(all.contains("> Green checks"), "no blockquote")
        XCTAssertTrue(all.contains("`Session.self`"), "no inline code")

        let longUrlLine = all.split(separator: "\n").first { $0.hasPrefix("https://") }
        XCTAssertNotNil(longUrlLine)
        XCTAssertGreaterThan(longUrlLine?.count ?? 0, 120, "the bare URL isn't long enough to need wrapping")
    }

    // MARK: - Terminal

    func testTerminalFramesIncludeLiveScrolledBackAndMissingLiveField() {
        let liveValues: [Bool?] = PaiFixtures.terminalFrames.map { jsonDict($0)["live"] as? Bool }
        XCTAssertTrue(liveValues.contains(true), "no live frame")
        XCTAssertTrue(liveValues.contains(false), "no scrolled-back (live: false) frame")
        XCTAssertTrue(liveValues.contains(nil), "no frame exercising the 'live absent' fallback")
    }

    // MARK: - Unhappy paths

    func testEmptyPagesAreActuallyEmptyArraysNotNullOrObjects() {
        for empty in [
            PaiFixtures.emptySessions, PaiFixtures.emptyMessages, PaiFixtures.emptyDrafts,
            PaiFixtures.emptyAgents, PaiFixtures.emptySearchResults,
        ] {
            XCTAssertEqual(jsonArray(empty).count, 0)
        }
    }

    /// `ApiError` is exactly `{ detail: string }` — `client.ts`'s `request()` throws
    /// `new Error(error.detail)` and nothing else survives the throw, so an extra key here would
    /// be dead weight nobody would ever notice was untested.
    func testErrorBodiesAreExactlyTheApiErrorShape() {
        for error in [PaiFixtures.errorSessionNotActive, PaiFixtures.errorNonJsonFallback] {
            let dict = jsonDict(error)
            XCTAssertEqual(Set(dict.keys), ["detail"])
            XCTAssertTrue(dict["detail"] is String)
        }
    }

    /// The documented invariant `client.ts` relies on: omitting `session_id` is what turns a
    /// send into "create this session from it". A fixture that added the key here would no
    /// longer represent the case it is named for.
    func testOutgoingPostMessageOmitsSessionIdOnlyForTheNewSessionCase() {
        XCTAssertFalse(jsonDict(PaiFixtures.outgoingPostMessageNewSession).keys.contains("session_id"))
        XCTAssertTrue(jsonDict(PaiFixtures.outgoingPostMessageExistingSession).keys.contains("session_id"))
    }

    // MARK: - The data() helper

    func testDataHelperRoundTripsUtf8JSON() throws {
        let data = PaiFixtures.data(PaiFixtures.healthOk)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["status"] as? String, "ok")
    }
}
