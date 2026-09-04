import Foundation

/// One visually distinct card a transcript row is made of.
///
/// A row is usually one card (a user bubble, a system line) but an assistant turn can be several —
/// an optional thinking block, one card per tool call, then its markdown reply — all produced by a
/// single ``Message``. ``TranscriptRowPlan/cards(for:isExpanded:)`` is the one place that decision
/// is made; both the row's measured height and the view that draws it consume the same plan, so
/// the two can never disagree about how many cards a message has or what order they come in — the
/// exact drift a hand-rolled `Card(call:, result:)` model would invite (tool calls and their
/// results are never paired in the data; see ``Kind/toolCall(_:)``/``Kind/toolResult(_:)``).
public struct TranscriptCardPlan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case thinking(text: String)
        /// A tool invocation, rendered inside the assistant turn that issued it.
        case toolCall(ToolCall)
        /// A tool's result, arriving as its own message and rendered as its own row — never
        /// paired with the call that produced it.
        case toolResult(ToolResult)
        /// A `notify` tool call's own reply — the bubble a notification jump (push, notification
        /// centre, kind stepping) now lands on, rendered as the notification it describes rather
        /// than the generic tool result's raw YAML. Always shown, unlike `.toolResult`: there is
        /// nothing to collapse into a one-line summary that would not just repeat the title.
        case notifyReply(title: String, body: String)
        case userBubble(text: String, attachmentPaths: [String])
        /// A genuine prompt relayed from another session (`subtype: "pai_message"`), drawn like
        /// Freddy's own bubble but coloured differently so a reader can tell it was not him.
        /// `group` is only ever set when `origin == "agent"` — the view needs nothing else to
        /// decide whether to show the "sender · group" pill.
        case relayedBubble(text: String, sender: String, group: String?)
        /// The second copy of a prompt Freddy sent, resent after an interrupt cut off the first
        /// (`subtype: "resent"`) — his own bubble, subdued, with a small label above it saying
        /// why it is there.
        case resentUserBubble(text: String, attachmentPaths: [String])
        /// `filePaths` is every `pai-file:` marker in `text` — `text` itself is the message's
        /// full, untouched content, marker lines included; see
        /// ``MessageRouting/extractFilePaths(_:)``.
        case assistantBubble(text: String, filePaths: [String])
        case agentMessage(sender: String, body: String)
        case command(name: String, args: String?)
        case system(subtype: String?, content: String?, hookSummary: HookSummary?)
        /// A `<local-command-…>` wrapper from before the parser classified that tag — permanent
        /// for rows ingested then; nothing re-parses a stored message.
        case legacyCommandOutput(content: String)
    }

    public let kind: Kind
    /// The key ``ExpandPreferences`` (and any per-row manual toggle) looks this card up under.
    /// `nil` for a card that is never collapsible — a user bubble, or a command's own arguments,
    /// which render unconditionally because a reader must never have to click to see their own
    /// words.
    public let expandKey: String?
    /// Whether this card is currently shown expanded — `true` unconditionally for a card with no
    /// `expandKey`, since those render unconditionally. Kept separate from `blocks.isEmpty`: a
    /// collapsible card that is expanded but whose body happens to be empty still has this `true`,
    /// which is what tells ``TranscriptRowLayout`` to reserve `CardChrome`'s content padding even
    /// though there are zero blocks to measure inside it.
    public let isExpanded: Bool
    /// What this card measures and renders, already resolved for the current expanded state: an
    /// empty array for a collapsed card, exactly what ``MessageContentLayoutComposer`` expects.
    /// Plain-text bodies (a tool call's spec text, a thinking block, system content) are wrapped
    /// as a single ``MarkdownBlock/codeBlock(language:code:)`` rather than measured by some
    /// separate path, so every card — markdown or not — goes through the one measured layout this
    /// package already proves.
    public let blocks: [MarkdownBlock]

    public init(kind: Kind, expandKey: String?, isExpanded: Bool, blocks: [MarkdownBlock]) {
        self.kind = kind
        self.expandKey = expandKey
        self.isExpanded = isExpanded
        self.blocks = blocks
    }
}

public enum TranscriptRowPlan {

    /// The ordered cards one message renders as. Empty for a route that shows nothing at all
    /// (``MessageRouting/Route/hidden`` and ``MessageRouting/Route/none``) — a caller filters
    /// those messages out of the row list entirely, rather than giving a collection view a row
    /// with nothing in it.
    ///
    public static func cards(for message: Message, isExpanded: (String) -> Bool) -> [TranscriptCardPlan] {
        switch MessageRouting.route(for: message) {
        case .system:
            return [
                systemCard(
                    subtype: message.subtype, content: message.content, hookSummary: message.hookSummary,
                    isExpanded: isExpanded)
            ]

        case .toolResult:
            guard let result = message.toolResult else { return [] }
            if let marker = message.notificationMarker, !marker.isEmpty,
                let reply = MessageDisplay.parseNotifyReply(result.content)
            {
                return [notifyReplyCard(title: reply.title, body: reply.body)]
            }
            return [toolResultCard(result, isExpanded: isExpanded)]

        case .hidden, .none:
            return []

        case .legacyCommandOutput(let content):
            let key = MessageRouting.systemExpandKey(subtype: "command_output")
            let expanded = isExpanded(key)
            return [
                TranscriptCardPlan(
                    kind: .legacyCommandOutput(content: content),
                    expandKey: key,
                    isExpanded: expanded,
                    blocks: expanded ? [codeBlock(content)] : []
                )
            ]

        case .user(let text, let attachmentPaths):
            return [
                TranscriptCardPlan(
                    kind: .userBubble(text: text, attachmentPaths: attachmentPaths),
                    expandKey: nil,
                    isExpanded: true,
                    blocks: text.isEmpty ? [] : [paragraph(text)]
                )
            ]

        case .agentMessage:
            let (label, body) = MessageDisplay.splitLabeledContent(message.content ?? "")
            let key = MessageRouting.systemExpandKey(subtype: "agent_message")
            let expanded = isExpanded(key)
            return [
                TranscriptCardPlan(
                    kind: .agentMessage(sender: label, body: body),
                    expandKey: key,
                    isExpanded: expanded,
                    blocks: expanded ? MarkdownParser.parse(body) : []
                )
            ]

        case .command:
            let (name, args) = MessageDisplay.splitLabeledContent(message.content ?? "")
            let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasArgs = !trimmedArgs.isEmpty
            return [
                TranscriptCardPlan(
                    kind: .command(name: name, args: hasArgs ? args : nil),
                    expandKey: nil,
                    isExpanded: true,
                    blocks: hasArgs ? [paragraph(args)] : []
                )
            ]

        case .relayedUser:
            let text = message.content ?? ""
            let sender = message.originMeta?["from"] ?? "Another session"
            let group = message.origin == "agent" ? message.originMeta?["group"] : nil
            return [
                TranscriptCardPlan(
                    kind: .relayedBubble(text: text, sender: sender, group: group),
                    expandKey: nil,
                    isExpanded: true,
                    blocks: text.isEmpty ? [] : [paragraph(text)]
                )
            ]

        case .resentUser(let text, let attachmentPaths):
            return [
                TranscriptCardPlan(
                    kind: .resentUserBubble(text: text, attachmentPaths: attachmentPaths),
                    expandKey: nil,
                    isExpanded: true,
                    blocks: text.isEmpty ? [] : [paragraph(text)]
                )
            ]

        case .systemFallback(let subtype, let content):
            return [
                systemCard(subtype: subtype, content: content, hookSummary: message.hookSummary, isExpanded: isExpanded)
            ]

        case .assistant:
            return assistantCards(for: message, isExpanded: isExpanded)
        }
    }

    // MARK: - Assistant turns

    private static func assistantCards(for message: Message, isExpanded: (String) -> Bool) -> [TranscriptCardPlan] {
        var cards: [TranscriptCardPlan] = []

        if let thinking = message.thinking, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = MessageRouting.thinkingExpandKey
            let expanded = isExpanded(key)
            cards.append(
                TranscriptCardPlan(
                    kind: .thinking(text: thinking), expandKey: key, isExpanded: expanded,
                    blocks: expanded ? [codeBlock(thinking)] : []))
        }

        for call in message.toolCalls ?? [] {
            let key = MessageRouting.toolExpandKey(name: call.name, isResult: false)
            let text = MessageDisplay.displayText(of: MessageDisplay.spec(for: call))
            let expanded = isExpanded(key)
            cards.append(
                TranscriptCardPlan(
                    kind: .toolCall(call), expandKey: key, isExpanded: expanded,
                    blocks: expanded ? [codeBlock(text)] : []))
        }

        if let content = message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cards.append(
                TranscriptCardPlan(
                    kind: .assistantBubble(text: content, filePaths: MessageRouting.extractFilePaths(content)),
                    expandKey: nil, isExpanded: true,
                    blocks: MarkdownParser.parse(content)))
        }

        return cards
    }

    // MARK: - System / tool-result cards

    private static func systemCard(
        subtype: String?, content: String?, hookSummary: HookSummary?, isExpanded: (String) -> Bool
    ) -> TranscriptCardPlan {
        let key = MessageRouting.systemExpandKey(subtype: subtype)
        // The `content` field is null on a hook row — the card draws from `hookSummary` instead,
        // never falling back to an empty body it would otherwise show.
        let body = (subtype == "hook") ? hookSummary.map(hookSummaryText) ?? "" : (content ?? "")
        let expanded = isExpanded(key)
        return TranscriptCardPlan(
            kind: .system(subtype: subtype, content: content, hookSummary: hookSummary),
            expandKey: key,
            isExpanded: expanded,
            blocks: expanded && !body.isEmpty ? [codeBlock(body)] : []
        )
    }

    private static func toolResultCard(_ result: ToolResult, isExpanded: (String) -> Bool) -> TranscriptCardPlan {
        let key = MessageRouting.toolExpandKey(name: result.toolName, isResult: true)
        let text = MessageDisplay.toolResultDisplayText(result, toolName: result.toolName)
        let expanded = isExpanded(key)
        return TranscriptCardPlan(
            kind: .toolResult(result), expandKey: key, isExpanded: expanded,
            blocks: expanded && !text.isEmpty ? [codeBlock(text)] : []
        )
    }

    private static func notifyReplyCard(title: String, body: String) -> TranscriptCardPlan {
        var blocks: [MarkdownBlock] = [paragraph(title)]
        if !body.isEmpty { blocks.append(paragraph(body)) }
        return TranscriptCardPlan(
            kind: .notifyReply(title: title, body: body), expandKey: nil, isExpanded: true, blocks: blocks)
    }

    private static func hookSummaryText(_ summary: HookSummary) -> String {
        var lines: [String] = [summary.hookNames.isEmpty ? "No hooks ran" : summary.hookNames.joined(separator: ", ")]
        if summary.hasErrors {
            lines.append(contentsOf: summary.errors.map { "- \($0)" })
        }
        if summary.preventedContinuation {
            lines.append("Prevented continuation")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Block wrapping

    /// A tool body, a thinking block and system content all render as a `<pre>` in the web — one
    /// monospaced block, not styled markdown — so wrapping as `.codeBlock` reuses the exact
    /// measurement and rendering path a real markdown code fence already goes through.
    private static func codeBlock(_ text: String) -> MarkdownBlock {
        .codeBlock(language: nil, code: text)
    }

    private static func paragraph(_ text: String) -> MarkdownBlock {
        .paragraph(InlineText(runs: [InlineRun(text: text)]))
    }
}
