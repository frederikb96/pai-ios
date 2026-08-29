import Foundation

/// Which shape a transcript row renders as, and the pieces of that decision `Message` does not
/// already carry on its own — the trailing attachment paths a plain user message hides inside its
/// text, and a legacy row's content once its wrapper has been peeled off.
///
/// Ported from `MessageBubble.tsx`'s branch order (`messageDisplay.ts` in the web owns the
/// per-shape rendering data this pairs with — `MessageDisplay` in this package mirrors that half).
/// Order matters: several branches are only reachable because an earlier one did not match, so
/// this is one function over the full order rather than several independent predicates a caller
/// could run out of sequence.
public enum MessageRouting {

    public enum Route: Equatable, Sendable {
        /// `type == "system"`.
        case system
        /// `type == "tool_result"` with a result payload — a result is never paired with the
        /// call that produced it; see the type's doc comment.
        case toolResult
        /// A legacy `<local-command-…>` wrapper of kind `caveat`, or with an empty inner body —
        /// renders nothing.
        case hidden
        /// A legacy `<local-command-…>` wrapper carrying real stdout, from a window before the
        /// parser classified that tag — a permanent shape; nothing re-parses an ingested row.
        case legacyCommandOutput(content: String)
        /// An ordinary message Freddy (or a device on his behalf) typed, with any trailing VM
        /// attachment paths already split out of the displayed text.
        case user(text: String, attachmentPaths: [String])
        case agentMessage
        /// A genuine prompt relayed here from another session by the backend
        /// (`subtype: "pai_message"`). It reads like a typed message rather than framework
        /// plumbing, because that is what it is — someone said it, just not into this session.
        /// Falling through to a system card would file a real instruction under machinery.
        case relayedUser
        /// A slash command or skill invocation, already in the clean `"{name}\n\n{args}"` shape.
        case command
        /// Any other `type == "user"` subtype, and a `command` row whose content is still the
        /// raw, unparsed `<command-name>` XML wrapper — both permanent shapes for rows ingested
        /// before the classifier that would have caught them, degrading to a plain system card
        /// rather than misreading the wrapper as the card's label.
        case systemFallback(subtype: String?, content: String?)
        case assistant
        /// A shape this build does not recognise — a message type this client predates, or a
        /// `tool_result` row with no result payload. Renders nothing, the same as the original's
        /// final unmatched branch.
        case none
    }

    public static func route(for message: Message) -> Route {
        switch message.type {
        case .system:
            return .system

        case .toolResult:
            return message.toolResult != nil ? .toolResult : .none

        case .user where message.subtype == nil:
            let content = message.content ?? ""
            if let legacy = MessageDisplay.legacyLocalCommandTag(content) {
                return legacy.kind == "caveat" || legacy.inner.isEmpty
                    ? .hidden
                    : .legacyCommandOutput(content: legacy.inner)
            }
            let extracted = extractAttachmentPaths(content)
            return .user(text: extracted.text, attachmentPaths: extracted.paths)

        case .user where message.subtype == "agent_message":
            return .agentMessage

        case .user where message.subtype == "pai_message":
            return .relayedUser

        case .user where message.subtype == "command":
            return MessageDisplay.isUnparsedCommandXml(message.content ?? "")
                ? .systemFallback(subtype: message.subtype, content: message.content)
                : .command

        case .user:
            return .systemFallback(subtype: message.subtype, content: message.content)

        case .assistant:
            return .assistant

        case .unrecognized:
            return .none
        }
    }

    // MARK: - Attachments

    /// Splits trailing VM attachment paths off a message's displayed text.
    ///
    /// Takes the last `"\n\n"`-separated block; if *every* whitespace-separated token in it
    /// matches the attachment path shape, that block is the attachment list and is stripped from
    /// the returned text — otherwise the content is returned unchanged with no paths. A block
    /// with no `"\n\n"` at all (an images-only send, whose prompt is just the paths with no
    /// leading text) is itself "the last block", so this still recognises it: splitting on the
    /// separator yields one element, and the returned text is correctly empty.
    public static func extractAttachmentPaths(_ content: String) -> (text: String, paths: [String]) {
        let parts = content.components(separatedBy: "\n\n")
        guard let lastBlock = parts.last else { return (content, []) }

        let tokens = lastBlock.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, tokens.allSatisfy(isAttachmentPathToken) else {
            return (content, [])
        }

        return (parts.dropLast().joined(separator: "\n\n"), tokens)
    }

    /// `\.claude/attachments/[^/\s]+/[^/\s]+$` — recognised by directory shape, never by
    /// extension, so any file at all can be attached.
    private static let attachmentPathRegex = try! NSRegularExpression(
        pattern: #"\.claude/attachments/[^/\s]+/[^/\s]+$"#
    )

    private static func isAttachmentPathToken(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..., in: token)
        return attachmentPathRegex.firstMatch(in: token, range: range) != nil
    }

    // MARK: - Expand-preference keys

    /// The nine tool families a card's expand key and its icon both switch on — kept as one
    /// function so the two can never independently drift onto different taxonomies.
    public static func toolFamily(_ name: String) -> String {
        let lower = name.lowercased()
        if lower == "bash" { return "bash" }
        if lower == "read" { return "read" }
        if lower.contains("edit") || lower == "write" || lower == "multiedit" { return "edit" }
        if lower == "grep" { return "grep" }
        if lower == "glob" { return "glob" }
        if lower.contains("agent") || lower == "task" { return "agent" }
        if lower == "websearch" || lower == "webfetch" { return "websearch" }
        if lower == "skill" { return "skill" }
        if lower.hasPrefix("mcp__") { return "mcp" }
        return "other"
    }

    public static func toolExpandKey(name: String, isResult: Bool) -> String {
        "\(toolFamily(name))_\(isResult ? "result" : "call")"
    }

    /// `subtype || 'system_other'` in the original, which is JavaScript truthiness — an empty
    /// string subtype falls to `system_other` too, not to `"system_"`. `!subtype.isEmpty` is
    /// what makes this Swift port agree with that rather than with a plain `!= nil` check.
    public static func systemExpandKey(subtype: String?) -> String {
        guard let subtype, !subtype.isEmpty else { return "system_other" }
        return "system_\(subtype)"
    }

    public static let thinkingExpandKey = "thinking"
}
