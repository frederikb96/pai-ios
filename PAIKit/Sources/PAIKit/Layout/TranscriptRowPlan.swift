import Foundation

/// One visually distinct card a transcript row is made of.
///
/// A row is usually one card (a user bubble, a system line) but an assistant turn can be several —
/// an optional thinking block, one card per tool call, then its markdown reply — all produced by a
/// single ``Message``. ``TranscriptRowPlan/cards(for:isRevealed:)`` is the one place that decision
/// is made; both the row's measured height and the view that draws it consume the same plan, so
/// the two can never disagree about how many cards a message has or what order they come in — the
/// exact drift a hand-rolled `Card(call:, result:)` model would invite (tool calls and their
/// results are never paired in the data; see ``Kind/toolCall(_:)``/``Kind/toolResult(_:)``).
public struct TranscriptCardPlan: Equatable, Sendable {

    /// Which of the three shapes this card draws as.
    ///
    /// The register, not the kind, is what decides the geometry: an activity row is a dense
    /// rail-and-marker grid, prose is Claude's own words at full width with no container at all,
    /// and `me` is a right-aligned bubble. Every kind maps to exactly one of them.
    public enum Register: Equatable, Sendable {
        /// Machinery: a tool call, its result, a thought, a system notice, an agent's report.
        case activity
        /// Claude's own reply. Not a bubble — a bubble around the longest text on screen is a
        /// container that only narrows it.
        case prose
        /// Something a person said: Freddy's own message, a relayed prompt, a command he invoked.
        case me
    }

    /// Colour is reserved for state, so there are only three tones and `normal` carries none.
    public enum Tone: Equatable, Sendable {
        case normal
        case warn
        case error
    }

    /// How much of this card's body is on screen.
    ///
    /// Two bounds, applied together: a source-line slice that decides how much text the card holds
    /// at all, and a visual line limit that decides how tall that text is allowed to draw. The
    /// first bounds what is laid out; the second is what stops one wrapped paragraph filling a
    /// phone. Either can be inactive — a body with no line structure worth slicing has no
    /// `hiddenLines`, and a body that is never clipped has no `visualLines`.
    public struct Preview: Equatable, Sendable {
        /// Source lines cut from the end of the body. `0` when the whole body is present.
        public let hiddenLines: Int
        /// Source lines in the *full* body — what `− show less (N lines)` names.
        public let totalLines: Int
        /// The visual line limit the drawing view applies, or `nil` when nothing is clipped.
        public let visualLines: Int?
        /// Whether text was removed before layout because the body was far longer than the clamp
        /// could ever draw. Carried explicitly rather than inferred from the measured height: how
        /// many characters a line fits is a property of the font, so a trim that happened to come
        /// out shorter than the cap would otherwise read as a body nothing was cut from — text
        /// gone, and no affordance to get it back.
        public let wasTrimmed: Bool

        public init(hiddenLines: Int, totalLines: Int, visualLines: Int?, wasTrimmed: Bool = false) {
            self.hiddenLines = hiddenLines
            self.totalLines = totalLines
            self.visualLines = visualLines
            self.wasTrimmed = wasTrimmed
        }

        /// A body shown whole, with no clipping.
        public static func full(totalLines: Int) -> Preview {
            Preview(hiddenLines: 0, totalLines: totalLines, visualLines: nil)
        }

        /// Whether either bound can still cut something. A card that is not bounded never draws a
        /// trailer and is never tappable, however long it is.
        public var isBounded: Bool { hiddenLines > 0 || wasTrimmed || visualLines != nil }
    }

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
        /// nothing to clip that would not just repeat the title.
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
    public let register: Register
    public let tone: Tone
    /// How this card's body is bounded *right now* — already resolved for the reveal state, so a
    /// revealed card carries ``Preview/full(totalLines:)`` rather than the bounds it would have had.
    public let preview: Preview
    /// Whether the reader has opened this card. Only meaningful for a card whose unrevealed
    /// `preview` was bounded; everything else is always whole.
    public let isRevealed: Bool
    /// What this card measures and renders, already resolved for the current reveal state — the
    /// sliced body when bounded, the whole body when revealed. Plain-text bodies (a tool call's
    /// spec text, a thinking block, system content) are wrapped as a single
    /// ``MarkdownBlock/codeBlock(language:code:)`` or ``MarkdownBlock/preformattedText(_:)``
    /// rather than measured by some separate path, so every card — markdown or not — goes through
    /// the one measured layout this package already proves.
    public let blocks: [MarkdownBlock]

    public init(
        kind: Kind, register: Register, tone: Tone = .normal, preview: Preview, isRevealed: Bool,
        blocks: [MarkdownBlock]
    ) {
        self.kind = kind
        self.register = register
        self.tone = tone
        self.preview = preview
        self.isRevealed = isRevealed
        self.blocks = blocks
    }
}

public enum TranscriptRowPlan {

    /// The ordered cards one message renders as. Empty for a route that shows nothing at all
    /// (``MessageRouting/Route/hidden`` and ``MessageRouting/Route/none``) — a caller filters
    /// those messages out of the row list entirely, rather than giving a collection view a row
    /// with nothing in it.
    ///
    /// `isRevealed` is asked by **card index within this message**, not by a shared preference
    /// key. An assistant turn's thought, its tool calls and its reply are separately openable for
    /// the same reason they are separate rows on the web: opening one to read a result should not
    /// unfold the thought above it. The caller binds the message id.
    public static func cards(for message: Message, isRevealed: (Int) -> Bool) -> [TranscriptCardPlan] {
        switch MessageRouting.route(for: message) {
        case .system:
            return [
                systemCard(
                    subtype: message.subtype, content: message.content, hookSummary: message.hookSummary,
                    index: 0, isRevealed: isRevealed)
            ]

        case .toolResult:
            guard let result = message.toolResult else { return [] }
            if let marker = message.notificationMarker, !marker.isEmpty,
                let reply = MessageDisplay.parseNotifyReply(result.content)
            {
                return [notifyReplyCard(title: reply.title, body: reply.body)]
            }
            return [toolResultCard(result, index: 0, isRevealed: isRevealed)]

        case .hidden, .none:
            return []

        case .legacyCommandOutput(let content):
            return [
                boundedActivityCard(
                    kind: .legacyCommandOutput(content: content), text: content,
                    budget: MessageDisplay.Preview.result, index: 0, isRevealed: isRevealed)
            ]

        case .user(let text, let attachmentPaths):
            return [
                TranscriptCardPlan(
                    kind: .userBubble(text: text, attachmentPaths: attachmentPaths),
                    register: .me,
                    preview: .full(totalLines: lineCount(text)),
                    isRevealed: true,
                    blocks: text.isEmpty ? [] : [paragraph(text)]
                )
            ]

        case .agentMessage:
            let (label, body) = MessageDisplay.splitLabeledContent(message.content ?? "")
            let revealed = isRevealed(0)
            return [
                TranscriptCardPlan(
                    kind: .agentMessage(sender: label, body: body),
                    register: .activity,
                    preview: revealed
                        ? .full(totalLines: lineCount(body))
                        : TranscriptCardPlan.Preview(
                            hiddenLines: 0, totalLines: lineCount(body),
                            visualLines: MessageDisplay.Preview.report.visual,
                            wasTrimmed: clampHeadroom(
                                body, visualLines: MessageDisplay.Preview.report.visual
                            ).count < body.count),
                    isRevealed: revealed,
                    // A report is markdown and renders as markdown whether or not it is clipped:
                    // the clip is a height cap on the rendered stack, not a different body. Only
                    // the head of it reaches the parser while clipped, since parsing is the
                    // expensive half and a report runs to tens of thousands of characters.
                    blocks: MarkdownParser.parse(
                        revealed ? body : clampHeadroom(body, visualLines: MessageDisplay.Preview.report.visual))
                )
            ]

        case .command:
            let (name, args) = MessageDisplay.commandParts(message.content ?? "")
            let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasArgs = !trimmedArgs.isEmpty
            let revealed = isRevealed(0)
            return [
                TranscriptCardPlan(
                    kind: .command(name: name, args: hasArgs ? args : nil),
                    register: .me,
                    preview: !hasArgs || revealed
                        ? .full(totalLines: lineCount(args))
                        : TranscriptCardPlan.Preview(
                            hiddenLines: 0, totalLines: lineCount(args),
                            visualLines: MessageDisplay.Preview.command.visual),
                    isRevealed: revealed,
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
                    register: .me,
                    preview: .full(totalLines: lineCount(text)),
                    isRevealed: true,
                    blocks: text.isEmpty ? [] : [paragraph(text)]
                )
            ]

        case .resentUser(let text, let attachmentPaths):
            return [
                TranscriptCardPlan(
                    kind: .resentUserBubble(text: text, attachmentPaths: attachmentPaths),
                    register: .me,
                    preview: .full(totalLines: lineCount(text)),
                    isRevealed: true,
                    blocks: text.isEmpty ? [] : [paragraph(text)]
                )
            ]

        case .systemFallback(let subtype, let content):
            return [
                systemCard(
                    subtype: subtype, content: content, hookSummary: message.hookSummary, index: 0,
                    isRevealed: isRevealed)
            ]

        case .assistant:
            return assistantCards(for: message, isRevealed: isRevealed)
        }
    }

    // MARK: - Assistant turns

    private static func assistantCards(for message: Message, isRevealed: (Int) -> Bool) -> [TranscriptCardPlan] {
        var cards: [TranscriptCardPlan] = []

        if let thinking = message.thinking, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let index = cards.count
            let revealed = isRevealed(index)
            cards.append(
                TranscriptCardPlan(
                    kind: .thinking(text: thinking),
                    register: .activity,
                    preview: revealed
                        ? .full(totalLines: lineCount(thinking))
                        : TranscriptCardPlan.Preview(
                            hiddenLines: 0, totalLines: lineCount(thinking),
                            visualLines: MessageDisplay.Preview.thinking.visual,
                            wasTrimmed: clampHeadroom(
                                thinking, visualLines: MessageDisplay.Preview.thinking.visual
                            ).count
                                < thinking.count),
                    isRevealed: revealed,
                    // Wraps rather than scrolling sideways: a thought is prose that happens to be
                    // one enormous source line, so a horizontal scroller would hide all of it.
                    blocks: [
                        .preformattedText(
                            revealed
                                ? thinking
                                : clampHeadroom(thinking, visualLines: MessageDisplay.Preview.thinking.visual))
                    ]
                ))
        }

        for call in message.toolCalls ?? [] {
            let index = cards.count
            cards.append(toolCallCard(call, index: index, isRevealed: isRevealed))
        }

        if let content = message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cards.append(
                TranscriptCardPlan(
                    kind: .assistantBubble(text: content, filePaths: MessageRouting.extractFilePaths(content)),
                    register: .prose,
                    preview: .full(totalLines: lineCount(content)),
                    isRevealed: true,
                    blocks: MarkdownParser.parse(content)))
        }

        return cards
    }

    /// A tool call's body, bounded by whichever budget its own shape earns — a diff gets more room
    /// than a file path, and a spawn's prompt is clipped to a glance because its identity is the
    /// part worth reading.
    private static func toolCallCard(_ call: ToolCall, index: Int, isRevealed: (Int) -> Bool) -> TranscriptCardPlan {
        let spec = MessageDisplay.spec(for: call)
        let text = MessageDisplay.displayText(of: spec)
        let revealed = isRevealed(index)

        switch spec {
        case .bash:
            return clampedActivityCard(
                kind: .toolCall(call), text: text, visual: MessageDisplay.Preview.command.visual,
                revealed: revealed)
        case .inline:
            // Never bounded: these are the arguments themselves — a path, a pattern, a query — and
            // they are short by construction. A path is also the one thing here where the end
            // carries more than the start, so cutting it tells the reader which directory and not
            // which file. It wraps to a second line where it needs to and nothing is hidden.
            return TranscriptCardPlan(
                kind: .toolCall(call), register: .activity, preview: .full(totalLines: lineCount(text)),
                isRevealed: true, blocks: text.isEmpty ? [] : [codeBlock(text)])
        case .edit:
            return slicedActivityCard(
                kind: .toolCall(call), text: text, budget: MessageDisplay.Preview.diff, revealed: revealed)
        case .write:
            return slicedActivityCard(
                kind: .toolCall(call), text: text, budget: MessageDisplay.Preview.write, revealed: revealed)
        case .agent:
            return clampedActivityCard(
                kind: .toolCall(call), text: text, visual: MessageDisplay.Preview.agentPrompt.visual,
                revealed: revealed)
        case .keyValue:
            return slicedActivityCard(
                kind: .toolCall(call), text: text, budget: MessageDisplay.Preview.keyValue, revealed: revealed)
        }
    }

    // MARK: - System / tool-result cards

    private static func systemCard(
        subtype: String?, content: String?, hookSummary: HookSummary?, index: Int, isRevealed: (Int) -> Bool
    ) -> TranscriptCardPlan {
        // The `content` field is null on a hook row — the card draws from `hookSummary` instead,
        // never falling back to an empty body it would otherwise show.
        let body = (subtype == "hook") ? hookSummary.map(hookSummaryText) ?? "" : (content ?? "")
        let kind = TranscriptCardPlan.Kind.system(subtype: subtype, content: content, hookSummary: hookSummary)
        let tone = systemTone(subtype: subtype, hookSummary: hookSummary)

        switch subtype {
        // An event whose whole meaning is that it happened, and whose body is one line in
        // practice — so it is not truncated, draws no trailer and takes no tap. Reveal is still
        // honoured rather than hardcoded open: hardcoding it made the row permanently "truncated"
        // and permanently captioned `show less`, an affordance saying the opposite of what the
        // row was doing, and the rare multi-line one (a misrouted agent message) unreadable.
        case "duration", "interrupt", "compact":
            let revealed = isRevealed(index)
            return TranscriptCardPlan(
                kind: kind, register: .activity, tone: tone,
                preview: revealed
                    ? .full(totalLines: lineCount(body))
                    : TranscriptCardPlan.Preview(hiddenLines: 0, totalLines: lineCount(body), visualLines: 1),
                isRevealed: revealed,
                blocks: body.isEmpty ? [] : [codeBlock(body)])

        // A compaction summary is a report: markdown, height-capped, opened by a tap.
        case "compact_summary":
            let revealed = isRevealed(index)
            return TranscriptCardPlan(
                kind: kind, register: .activity, tone: tone,
                preview: revealed
                    ? .full(totalLines: lineCount(body))
                    : TranscriptCardPlan.Preview(
                        hiddenLines: 0, totalLines: lineCount(body),
                        visualLines: MessageDisplay.Preview.report.visual,
                        wasTrimmed: clampHeadroom(
                            body, visualLines: MessageDisplay.Preview.report.visual
                        ).count < body.count),
                isRevealed: revealed,
                blocks: MarkdownParser.parse(
                    revealed ? body : clampHeadroom(body, visualLines: MessageDisplay.Preview.report.visual)))

        // A hook that went wrong is the one system row worth reading in full, so it earns the
        // error budget; a quiet one is noise and gets two lines.
        case "hook":
            return tone == .normal
                ? clampedActivityCard(
                    kind: kind, text: body, visual: MessageDisplay.Preview.noise.visual,
                    revealed: isRevealed(index), tone: tone)
                : slicedActivityCard(
                    kind: kind, text: body, budget: MessageDisplay.Preview.resultError,
                    revealed: isRevealed(index), tone: tone)

        default:
            return clampedActivityCard(
                kind: kind, text: body, visual: MessageDisplay.Preview.noise.visual, revealed: isRevealed(index),
                tone: tone)
        }
    }

    /// Amber for a hook that reported errors or stopped the turn, and for an interrupt — both are
    /// states a reader scrolling back is looking for. Nothing else in the system register carries
    /// colour at all.
    private static func systemTone(subtype: String?, hookSummary: HookSummary?) -> TranscriptCardPlan.Tone {
        switch subtype {
        case "hook":
            guard let hookSummary else { return .normal }
            return hookSummary.hasErrors || hookSummary.preventedContinuation ? .warn : .normal
        case "interrupt":
            return .warn
        default:
            return .normal
        }
    }

    private static func toolResultCard(
        _ result: ToolResult, index: Int, isRevealed: (Int) -> Bool
    ) -> TranscriptCardPlan {
        let text = MessageDisplay.toolResultDisplayText(result, toolName: result.toolName)
        let failed = result.isError
        return slicedActivityCard(
            kind: .toolResult(result), text: text,
            budget: failed ? MessageDisplay.Preview.resultError : MessageDisplay.Preview.result,
            revealed: isRevealed(index), tone: failed ? .error : .normal)
    }

    private static func notifyReplyCard(title: String, body: String) -> TranscriptCardPlan {
        var blocks: [MarkdownBlock] = [paragraph(title)]
        if !body.isEmpty { blocks.append(paragraph(body)) }
        return TranscriptCardPlan(
            kind: .notifyReply(title: title, body: body), register: .activity,
            preview: .full(totalLines: lineCount(title) + lineCount(body)), isRevealed: true, blocks: blocks)
    }

    // MARK: - Card builders

    /// A body cut to a source-line budget *and* capped visually — the two bounds together, which
    /// is what keeps one long line from filling a phone after the line slice already passed.
    private static func slicedActivityCard(
        kind: TranscriptCardPlan.Kind, text: String, budget: MessageDisplay.PreviewBudget, revealed: Bool,
        tone: TranscriptCardPlan.Tone = .normal
    ) -> TranscriptCardPlan {
        let slice = MessageDisplay.previewLines(text, budget)
        let shown = revealed ? text : slice.shown
        return TranscriptCardPlan(
            kind: kind, register: .activity, tone: tone,
            preview: revealed
                ? .full(totalLines: slice.total)
                : TranscriptCardPlan.Preview(
                    hiddenLines: slice.hidden, totalLines: slice.total, visualLines: budget.visual),
            isRevealed: revealed,
            blocks: shown.isEmpty ? [] : [codeBlock(shown)])
    }

    /// A body with no line structure worth slicing — bounded by its visual limit alone.
    private static func clampedActivityCard(
        kind: TranscriptCardPlan.Kind, text: String, visual: Int, revealed: Bool,
        tone: TranscriptCardPlan.Tone = .normal
    ) -> TranscriptCardPlan {
        let shown = revealed ? text : clampHeadroom(text, visualLines: visual)
        return TranscriptCardPlan(
            kind: kind, register: .activity, tone: tone,
            preview: revealed
                ? .full(totalLines: lineCount(text))
                : TranscriptCardPlan.Preview(
                    hiddenLines: 0, totalLines: lineCount(text), visualLines: visual,
                    wasTrimmed: shown.count < text.count),
            isRevealed: revealed,
            blocks: shown.isEmpty ? [] : [codeBlock(shown)])
    }

    /// Far more text than `visualLines` can ever hold, and not one character more.
    ///
    /// A visual clamp cuts by height, which means the whole body would otherwise be laid out in
    /// full just to be clipped — and the bodies clamped this way are the unbounded ones: a thought
    /// is a single source line that routinely runs past a thousand characters, and a subagent's
    /// report can run to tens of thousands. Measuring all of it, per row, to show two lines is
    /// work nobody sees.
    ///
    /// 200 characters per line is roughly four times what the narrowest real line fits, so a body
    /// this keeps is still comfortably longer than the clamp can draw — the cut is never what
    /// decides whether the clamp bit, only how much the measurer had to read to find out.
    private static func clampHeadroom(_ text: String, visualLines: Int) -> String {
        let limit = visualLines * 200
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    private static func boundedActivityCard(
        kind: TranscriptCardPlan.Kind, text: String, budget: MessageDisplay.PreviewBudget, index: Int,
        isRevealed: (Int) -> Bool
    ) -> TranscriptCardPlan {
        slicedActivityCard(kind: kind, text: text, budget: budget, revealed: isRevealed(index))
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

    /// A tool body and system content both render as one monospaced block, not styled markdown, so
    /// wrapping as `.codeBlock` reuses the exact measurement and rendering path a real markdown
    /// code fence already goes through. The Thinking card is the one exception: see
    /// `.preformattedText` for why it wraps instead of scrolling sideways.
    private static func codeBlock(_ text: String) -> MarkdownBlock {
        .codeBlock(language: nil, code: text)
    }

    private static func paragraph(_ text: String) -> MarkdownBlock {
        .paragraph(InlineText(runs: [InlineRun(text: text)]))
    }

    /// Source lines in a body, counted the way ``MessageDisplay/previewLines(_:_:)`` counts them,
    /// so `− show less (N lines)` names the same number the slice was taken from.
    private static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
