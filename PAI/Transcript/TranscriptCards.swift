import Foundation
import PAIKit
import SwiftUI
import UIKit

/// Re-exports ``TranscriptRowMetrics/markdownBlockSpacing`` under the name both this file (the
/// rendered spacing) and `TranscriptCollectionViewController` (the measured spacing, threaded
/// through `MessageLayoutMetrics`) already call it. The value itself lives in `PAIKit` rather
/// than here now, because ``NestedBlockLayout`` needs it too, for the identical gap between a
/// list item's or block quote's own nested blocks — a design-token decision this file used to own
/// alone, until measuring it correctly required reading it from the same place twice.
enum TranscriptContentMetrics {
    static let blockSpacing = TranscriptRowMetrics.markdownBlockSpacing
}

/// One occurrence to paint inside a block's own text, in that block's UTF-16 coordinates — the
/// shape every rendering function below takes its highlights in.
typealias TranscriptHighlightSpan = (range: NSRange, isCurrent: Bool)

extension Shape where Self == UnevenRoundedRectangle {
    /// Freddy's own bubble shape — a native uneven rectangle rather than a hand-drawn tail, one
    /// corner tucked in on the edge the bubble is addressed from, matching the web's `rounded-2xl
    /// rounded-br-md`. Shared by every right-aligned bubble in this file (his own prompt, a
    /// relayed one, a command with arguments): one definition, so the three can never pick
    /// slightly different radii.
    static var ownBubbleTail: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 6, topTrailingRadius: 16)
    }

    /// The mirror of ``ownBubbleTail`` for a bubble addressed from the left, matching the web's
    /// `rounded-2xl rounded-bl-md`.
    static var replyBubbleTail: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 16, bottomLeadingRadius: 6, bottomTrailingRadius: 16, topTrailingRadius: 16)
    }
}

/// The web pairs a raw-scale colour with a specific step per appearance at every call site
/// (`bg-primary-500 dark:bg-primary-600`) rather than baking the pairing into one asset — every
/// step in ``PaiPalette``'s raw scale is a fixed swatch that never varies by appearance on its
/// own (see that file's own doc comment). This mirrors the web's pairing for a bubble's own fill,
/// the one place in this file that needs it.
private func bubbleFill(light: Color, dark: Color, colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? dark : light
}

/// One message's whole row: every card `TranscriptRowPlan` produced for it, in order — the exact
/// same decomposition `TranscriptRowLayout` measured, so a row never renders taller or shorter
/// than the height its cell was given.
///
/// The cards arrive already measured rather than being re-planned here. Whether a bounded body
/// actually overflowed is a measured fact that decides two things at once — whether the row
/// reserved a trailer line, and whether this draws one — and a view deciding that for itself is
/// the same conclusion computed twice, which is exactly how a drawn row comes to disagree with
/// its own height.
///
/// No row carries a time of its own. A gutter for one costs its width on every row of every
/// screen to answer a question a reader asks a handful of times a session; a separator above the
/// rows that begin a new stretch answers it where it is asked, and gives the width back.
struct TranscriptRowContent: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: Message
    let cards: [MeasuredCard]
    let metrics: MessageLayoutMetrics
    /// Threaded explicitly rather than read from `AppEnvironment` — a cell's `UIHostingConfiguration`
    /// content is its own SwiftUI tree, rooted at the collection view, not a descendant of the
    /// screen's own environment, so a value nothing here builds must be handed in like any other
    /// property. Both come from the same place `apiClient` already does for every other transcript
    /// network call (`TranscriptCollectionViewController`'s own stored properties).
    let sessionID: String
    let apiClient: PaiApiClient
    /// Called with the index of the card the reader tapped — reveal is per segment, so opening a
    /// tool result does not also unfold the thought above it.
    let onToggleReveal: (Int) -> Void
    /// The time to draw above this row, or `nil` for the rows between. Decided by the caller,
    /// which is the only place that can see the row above this one — and decided identically for
    /// the height, since a separator the height reserved and the view omitted is a gap.
    var timeSeparator: String? = nil
    /// Every search hit that belongs to this message — already filtered by the caller, which
    /// knows the message id and this view does not need to. Empty outside a search.
    var highlights: [TranscriptSearchHit] = []
    var currentHit: TranscriptSearchHit?
    /// Whether this is the row a notification deep link just landed on, OR the current search
    /// hit's own row — the web draws one ring for both ("the two should not [visually] differ",
    /// `MessageBubble.tsx`'s own comment), since a deep link and a kind search both target a whole
    /// message with no text range to paint via `highlights`/`currentHit`, and a landing on a text
    /// hit wants its row visibly marked too, not only the highlighted span inside it.
    var isRinged = false

    var body: some View {
        // No spacing between cards: the gap is a property of each register's own padding, not of
        // the pair, which is what lets a run of activity rows share one unbroken rail.
        VStack(alignment: .leading, spacing: 0) {
            if let timeSeparator {
                TimeSeparatorView(text: timeSeparator, lineHeight: metrics.trailerLineHeight)
            }
            // The cards get their own stack so the ring below encloses the message and not the
            // separator above it — a landing that happens to begin a new stretch of time would
            // otherwise draw the centred date inside the highlight, reading as part of what was
            // landed on. 🚨 A real VStack, not the modifiers moved onto the `ForEach`: SwiftUI
            // distributes a layout modifier over a multi-view, so a ring applied there would be
            // one ring per card.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.offset) { cardIndex, card in
                    TranscriptCardKindView(
                        card: card,
                        metrics: metrics,
                        // The MEASURED truth, not the plan's intent: a bounded card whose body
                        // turned out to fit has nothing to open, and offering a tap there is an
                        // affordance that does nothing.
                        onToggle: card.isTruncated || card.plan.isRevealed
                            ? { onToggleReveal(cardIndex) } : nil,
                        sessionID: sessionID,
                        apiClient: apiClient,
                        highlightsByBlockIndex: highlightsByBlockIndex(forCardIndex: cardIndex)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // An overlay, never a border baked into the frame — it must not add a point to the
            // row's measured height, which `TranscriptRowLayout` already computed for a plain
            // bubble.
            //
            // 🚨 And it must draw INSIDE that frame: `strokeBorder` puts the whole stroke within
            // the shape rather than centred on its edge, and there is no negative padding pushing
            // it out. A cell clips its content, so a ring drawn outside the row's own bounds does
            // not arrive with a clipped edge — it does not arrive at all, and this ring is the
            // only thing that says a deep link or a search step landed here.
            .overlay {
                if isRinged {
                    RoundedRectangle(cornerRadius: 10)
                        // Matches the web's `ring-yellow-400 dark:ring-yellow-500` — the same ring
                        // its own `MessageBubble.tsx` comment says a search current-match and a
                        // deep link "should not [visually] differ", one token apart only so each
                        // can toggle independently. `primary500` here was a genuine colour
                        // mismatch, not a missing token: the web's ring is yellow, not blue.
                        .strokeBorder(
                            bubbleFill(
                                light: PaiPalette.yellow400, dark: PaiPalette.yellow500,
                                colorScheme: colorScheme),
                            lineWidth: 2
                        )
                        .padding(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Groups this card's own hits by which block they fall in — the shape every rendering
    /// function downstream wants, since a card's content is measured and drawn block by block.
    private func highlightsByBlockIndex(forCardIndex cardIndex: Int) -> [Int: [TranscriptHighlightSpan]] {
        guard !highlights.isEmpty else { return [:] }
        var result: [Int: [TranscriptHighlightSpan]] = [:]
        for hit in highlights where hit.cardIndex == cardIndex {
            result[hit.blockIndex, default: []].append((hit.range, hit == currentHit))
        }
        return result
    }
}

/// The time between two stretches of a session. Centred, quiet, and one line tall — the row
/// reserved exactly that, from the same font it draws in.
private struct TimeSeparatorView: View {
    let text: String
    let lineHeight: Double

    var body: some View {
        Text(text)
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textFaint)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: lineHeight)
            .padding(.vertical, TranscriptRowMetrics.timeSeparatorPadding)
    }
}

/// Routes one card to its specific presentation.
///
/// The register decides the shape, not the kind: everything that is machinery draws as an
/// ``ActivityRowView``, Claude's own reply draws as prose with no container around it at all, and
/// anything a person said keeps its bubble.
struct TranscriptCardKindView: View {
    let card: MeasuredCard
    let metrics: MessageLayoutMetrics
    let onToggle: (() -> Void)?
    let sessionID: String
    let apiClient: PaiApiClient
    var highlightsByBlockIndex: [Int: [TranscriptHighlightSpan]] = [:]

    var body: some View {
        switch card.plan.kind {
        case .thinking:
            activity(icon: "brain", label: "Thinking") {
                ToolBodyText(blocks: card.plan.blocks, highlightsByBlockIndex: highlightsByBlockIndex)
            }

        case .toolCall(let call):
            activity(
                icon: TranscriptCardKindView.toolIcon(call.name),
                label: MessageDisplay.toolCardLabel(call: call, result: nil)
            ) {
                ToolBodyText(
                    blocks: card.plan.blocks,
                    colorHint: TranscriptCardKindView.colorHint(forToolName: call.name),
                    highlightsByBlockIndex: highlightsByBlockIndex)
            }

        case .toolResult(let result):
            // A result that worked carries no label: its glyph and its place under the call are
            // the label, the way a terminal's own output marker works. A failed one says so,
            // because that is the row a reader scrolling back is looking for.
            activity(
                icon: TranscriptCardKindView.toolIcon(result.toolName),
                label: result.isError
                    ? "\(MessageDisplay.toolCardLabel(call: nil, result: result)) failed" : nil
            ) {
                // A result is plain, unlike its call — only a bash command line or an edit's
                // diff prefixes are recoloured; a result's own output has neither.
                ToolBodyText(blocks: card.plan.blocks, highlightsByBlockIndex: highlightsByBlockIndex)
            }

        case .notifyReply:
            activity(icon: "bell", label: "Notification sent") {
                MarkdownContentView(blocks: card.plan.blocks, highlights: highlightsByBlockIndex)
            }

        case .userBubble(let text, let attachmentPaths):
            me {
                UserBubbleView(
                    text: text, attachmentPaths: attachmentPaths, sessionID: sessionID, apiClient: apiClient,
                    highlights: highlightsByBlockIndex[0] ?? [])
            }

        case .relayedBubble(let text, let sender, let group):
            me {
                RelayedBubbleView(
                    text: text, sender: sender, group: group, highlights: highlightsByBlockIndex[0] ?? [])
            }

        case .resentUserBubble(let text, let attachmentPaths):
            me {
                ResentBubbleView(
                    text: text, attachmentPaths: attachmentPaths, sessionID: sessionID, apiClient: apiClient,
                    highlights: highlightsByBlockIndex[0] ?? [])
            }

        case .assistantBubble(_, let filePaths):
            ProseRowView {
                AssistantProseView(
                    blocks: card.plan.blocks, filePaths: filePaths, sessionID: sessionID, apiClient: apiClient,
                    highlights: highlightsByBlockIndex)
            }

        case .agentMessage(let sender, _):
            activity(icon: "bubble.left.and.bubble.right", label: sender) {
                MarkdownContentView(blocks: card.plan.blocks, highlights: highlightsByBlockIndex)
            }

        case .command(let name, let args):
            me {
                CommandCardView(name: name, args: args, highlights: highlightsByBlockIndex[0] ?? [])
            }

        case .system(let subtype, let content, _):
            activity(
                icon: TranscriptCardKindView.systemIcon(subtype),
                label: MessageDisplay.systemLabel(subtype: subtype, content: content)
            ) {
                ToolBodyText(blocks: card.plan.blocks, highlightsByBlockIndex: highlightsByBlockIndex)
            }

        case .legacyCommandOutput:
            activity(icon: "terminal", label: "Output") {
                ToolBodyText(blocks: card.plan.blocks, highlightsByBlockIndex: highlightsByBlockIndex)
            }
        }
    }

    private func activity(
        icon: String, label: String?, @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        ActivityRowView(
            icon: icon, label: label, card: card, metrics: metrics, onToggle: onToggle, content: content)
    }

    private func me(@ViewBuilder content: @escaping () -> some View) -> some View {
        MeRowView(content: content)
    }

    /// Mirrors the web's `toolIcon` — bash/read/edit/grep/glob/agent/web/skill/mcp, default
    /// terminal. Kept as SF Symbol names rather than the web's icon components.
    fileprivate static func toolIcon(_ name: String) -> String {
        let lower = name.lowercased()
        if lower == "bash" { return "terminal" }
        if lower == "read" { return "doc.text" }
        if lower.contains("edit") || lower == "write" || lower == "multiedit" { return "pencil" }
        if lower == "grep" { return "magnifyingglass" }
        if lower == "glob" { return "folder" }
        if lower.contains("agent") || lower == "task" { return "cpu" }
        if lower == "websearch" || lower == "webfetch" { return "globe" }
        if lower == "skill" { return "bolt" }
        if lower.hasPrefix("mcp__") { return "puzzlepiece" }
        return "terminal"
    }

    fileprivate static func systemIcon(_ subtype: String?) -> String {
        switch subtype {
        case "skill": return "bolt"
        case "context": return "info.circle"
        case "command", "command_output": return "terminal"
        case "image": return "photo"
        case "compact", "compact_summary": return "quote.opening"
        case "hook": return "bolt"
        case "duration": return "info.circle"
        case "interrupt": return "stop.circle"
        case "notification": return "bell"
        case "scheduled": return "clock"
        case "pai_message": return "info.circle"
        default: return "info.circle"
        }
    }

    /// A bash command's `$ ` line and an edit's `- `/`+ ` diff lines are the two places the web
    /// colours a tool body by content rather than by syntax highlighting — neither changes the
    /// text, so neither can change a measured height.
    fileprivate static func colorHint(forToolName name: String) -> ToolBodyColorHint? {
        let lower = name.lowercased()
        if lower == "bash" { return .bashCommand }
        if lower.contains("edit") { return .diff }
        return nil
    }
}

/// A shared icon scale for an activity row's marker glyph — one size for every kind, so a run of
/// rows reads as one column rather than as a ragged edge.
private let activityIconFont = Font.system(size: 12, weight: .medium)

/// One row of machinery: a rail, a marker, a label line, an optional header and a bounded body.
///
/// There is no chevron and no box. Six kinds of card filling the same outlined slab is what made
/// the transcript unreadable as "which of these is the answer"; a rail down the left reads as one
/// stream of activity, and the eye skips the whole stream to find the prose between runs of it.
///
/// Every constant here is ``TranscriptRowMetrics``, not a local number: this view's own height and
/// the height ``TranscriptRowLayout`` computed for it must never drift apart, and the surest way
/// to guarantee that is to have exactly one definition of each. The body is clipped to the
/// content height the layout already measured rather than to a limit computed again here, for the
/// same reason.
struct ActivityRowView<Content: View>: View {
    let icon: String
    /// Absent where the row's own position is the label — a successful tool result under its call.
    let label: String?
    let card: MeasuredCard
    let metrics: MessageLayoutMetrics
    let onToggle: (() -> Void)?
    @ViewBuilder let content: () -> Content

    private var railColor: Color {
        switch card.plan.tone {
        case .error: return PaiPalette.red500
        case .warn: return PaiPalette.amber500
        case .normal: return PaiPalette.Semantic.borderStrong
        }
    }

    private var labelColor: Color {
        switch card.plan.tone {
        case .error: return PaiPalette.red500
        case .warn: return PaiPalette.amber500
        case .normal: return PaiPalette.Semantic.textMuted
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(railColor)
                .frame(width: TranscriptRowMetrics.railWidth)
            Image(systemName: icon)
                .font(activityIconFont)
                .foregroundStyle(card.plan.tone == .normal ? PaiPalette.Semantic.textFaint : labelColor)
                .frame(width: TranscriptRowMetrics.markerColumnWidth, height: metrics.activityLineHeight)
            VStack(alignment: .leading, spacing: 0) {
                // Pinned to exactly one line, in both directions: a label that wrapped would make
                // the row taller than it was measured to be, and one that collapsed would make it
                // shorter. The row reserves this line whether or not there is a word in it.
                Text(label ?? " ")
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: metrics.activityLineHeight, alignment: .leading)
                if let header = card.plan.header {
                    // Wraps, never scrolls, never clipped: the point of lifting a path out of the
                    // body is that it stays readable whatever the body is doing. Soft-broken the
                    // same way the measurer broke it, since a path has nowhere to wrap on its own.
                    Text(LongTokenSoftBreaker.apply(to: header).text)
                        .font(PaiTypography.markdownCodeBlock.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, metrics.blockSpacing)
                }
                // One container, one clip. Applied to `content()` directly it would land on each
                // block a multi-block body is made of — every paragraph given the whole allowance
                // to itself, and a row drawn several times the height its cell was given.
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(height: card.contentHeight, alignment: .top)
                .clipped()
                if card.isTruncated {
                    TrailerView(
                        preview: card.plan.preview, isRevealed: card.plan.isRevealed,
                        lineHeight: metrics.trailerLineHeight)
                }
            }
            // Claims the whole body column rather than leaving a flexible spacer to compete for
            // it: a spacer would squeeze long text narrower than the width it was measured at,
            // and narrower text is taller text.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TranscriptRowMetrics.gridGap)
        }
        .padding(.vertical, TranscriptRowMetrics.activityRowPadding)
        .padding(.leading, TranscriptRowMetrics.activityHorizontalInset)
        .padding(
            .trailing, TranscriptRowMetrics.activityTrailingInset + TranscriptRowMetrics.contentTrailingGutter
        )
        .background(card.plan.tone == .error ? PaiPalette.red500.opacity(0.06) : Color.clear)
        // The whole row answers a tap, not a chevron: on a phone there is no room for a target
        // beside the text, and a row is one thing to the reader whatever it is made of.
        //
        // 🚨 Only the GESTURE is conditional. Switching hit testing off for a row with nothing to
        // reveal takes its sideways-scrolling code block with it — so whether a command could be
        // read at all came down to whether that same row happened to have something hidden behind
        // it, which is invisible from here and reads as scrolling that works on some rows and not
        // others.
        .contentShape(Rectangle())
        .onTapGesture { onToggle?() }
        // The header is part of what this row says, so it is part of what copying it yields —
        // matching the web, whose own copy text has always carried the path.
        .transcriptRowCopy(
            text: ([card.plan.header] + card.plan.blocks.map(\.plainText))
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}

/// Claude's own reply: no container at all, and the full width of the row.
///
/// A bubble around the longest text on screen is a box that only narrows what there is to read,
/// and it makes the reply look like one more card in a stack of machinery rather than the answer.
struct ProseRowView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, TranscriptRowMetrics.proseRowPadding)
            .padding(.leading, TranscriptRowMetrics.activityHorizontalInset)
            .padding(
                .trailing, TranscriptRowMetrics.activityTrailingInset + TranscriptRowMetrics.contentTrailingGutter
            )
            // 🚨 The wash is applied AFTER every padding and adds none of its own, so it changes
            // no geometry whatever: a background paints the frame it is given, and this row's
            // frame is exactly what `TranscriptRowLayout` already measured. Insetting it would
            // narrow the text without the measurement knowing, which is the disagreement that
            // clips a line off the bottom of a row.
            .background(
                bubbleFill(
                    light: PaiPalette.assistant500, dark: PaiPalette.assistant400,
                    colorScheme: colorScheme
                )
                .opacity(colorScheme == .dark ? 0.07 : 0.06),
                in: RoundedRectangle(cornerRadius: 10)
            )
    }
}

/// Something a person said — right-aligned, keeping its bubble, ending at the same right edge
/// every other register does.
struct MeRowView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.vertical, TranscriptRowMetrics.meRowPadding)
            .padding(.leading, TranscriptRowMetrics.activityHorizontalInset)
            .padding(.trailing, TranscriptRowMetrics.activityTrailingInset)
    }
}

/// The one line under a bounded body saying what is behind it, and the only affordance a reveal
/// has. Its height is fixed because the row reserved exactly that much for it.
private struct TrailerView: View {
    let preview: TranscriptCardPlan.Preview
    let isRevealed: Bool
    /// The row reserved exactly this much for it, from the same font this draws in.
    let lineHeight: Double

    private var caption: String {
        if isRevealed { return "− show less (\(preview.totalLines) \(lineWord(preview.totalLines)))" }
        if preview.hiddenLines > 0 { return "… +\(preview.hiddenLines) \(lineWord(preview.hiddenLines))" }
        return "… more"
    }

    private func lineWord(_ count: Int) -> String { count == 1 ? "line" : "lines" }

    var body: some View {
        Text(caption)
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.accentText)
            .lineLimit(1)
            .frame(height: lineHeight, alignment: .leading)
    }
}

extension View {
    /// A long press copies the row's own text verbatim — the command or the output, which is what
    /// somebody pasting it into a terminal needs, and distinct from copying a whole message as
    /// Markdown. The native gesture rather than an icon: a button beside the text would cost the
    /// width this design exists to reclaim.
    func transcriptRowCopy(text: String) -> some View {
        contextMenu {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}

/// A code block's own horizontally-scrolling container — shared by `ToolBodyText` and
/// `MarkdownContentView`'s `.codeBlock` case, so revealing the current search hit's own column
/// lives in exactly one place rather than growing a second, drifting copy.
///
/// Vertical reveal (which LINE) is `revealHit`'s own job, upstream of this view — this only ever
/// moves the horizontal offset, and only for the current hit's own column. A row landing with no
/// text occurrence (a kind hit, a deep link) has no column to reveal, so `highlights` is simply
/// empty then and this does nothing, same as it always did before search existed.
private struct CodeBlockScrollView<Content: View>: View {
    let code: String
    let highlights: [TranscriptHighlightSpan]
    @ViewBuilder let content: () -> Content

    @State private var position = ScrollPosition()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            content()
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(TranscriptRowMetrics.codeBlockPadding)
        }
        .scrollPosition($position)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 6))
        .onAppear { revealCurrentHit() }
        .onChange(of: currentHitRange) { _, _ in revealCurrentHit() }
    }

    private var currentHitRange: NSRange? {
        highlights.first { $0.isCurrent }?.range
    }

    /// Centres the current hit's own column under the viewport — the horizontal counterpart to
    /// `revealHit`'s vertical centring, using the same `CodeBlockHitGeometry` a search landing
    /// already computed the line from. `glyphAdvance` converts a column straight to points because
    /// a code block never wraps and every glyph in a monospaced font is the same width — no text
    /// layout pass needed to answer "how far across is column N".
    private func revealCurrentHit() {
        guard let range = currentHitRange else { return }
        let column = CodeBlockHitGeometry.position(of: range, in: code).column
        let x = max(
            0, Double(column) * CodeBlockScrollGeometry.glyphAdvance - CodeBlockScrollGeometry.viewportEstimate / 2)
        position.scrollTo(x: x)
    }
}

/// The two measurements ``CodeBlockScrollView``'s horizontal centring needs, pulled out of that
/// type because a generic type cannot carry a static stored property at all (a Swift language
/// limit, not a style choice) — `CodeBlockScrollView<Content>` is generic over what it draws.
private enum CodeBlockScrollGeometry {
    /// A generous stand-in for "half the code block's own visible width". The real viewport width
    /// needs a `GeometryReader`, which would then also govern the view's own measurement — and
    /// this package's row heights are computed independently of what any view reports (the
    /// `scrolling` skill's central rule), so nothing here may become a second source of that
    /// number. Erring wide only ever undershoots the centring; `ScrollView` already clamps past
    /// the text's end.
    static let viewportEstimate: Double = 320

    static let glyphAdvance: Double = {
        let pointSize = PaiTypography.markdownCodeBlock.pointSize(for: .large)
        let font = UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: font]).width
    }()
}

/// A card body wrapped as a single `.codeBlock` (see `TranscriptRowPlan`'s doc comment on why) —
/// rendered monospaced on a raised ground, matching the web's `<pre>` (`bg-surface-100
/// dark:bg-surface-800`, the same pairing ``PaiPalette/Semantic/raisedSurface`` already carries —
/// a fixed `surface900` read as a black box in light mode). `colorHint` recolours whole lines by
/// their literal prefix (`$ `, `- `, `+ `) without touching the text itself, so a measured height
/// built from the same string is never invalidated by how it is painted.
struct ToolBodyText: View {
    let blocks: [MarkdownBlock]
    var colorHint: ToolBodyColorHint?
    var highlightsByBlockIndex: [Int: [TranscriptHighlightSpan]] = [:]

    /// Stacked with exactly the gap ``MessageContentLayoutComposer`` put between the same blocks
    /// when it measured them — a body of one block (nearly every tool card) is unaffected, and a
    /// body of many (a compaction summary, an agent's report) is the case that was drawn tighter
    /// than it was measured.
    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptContentMetrics.blockSpacing) {
            blockViews
        }
    }

    @ViewBuilder
    private var blockViews: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
            if case .codeBlock(_, let code) = block {
                // Scrolls sideways rather than wrapping, exactly as `MarkdownContentView` draws
                // the same block — and for a reason beyond matching the web's `overflow-x-auto`:
                // `TextKitBlockMeasurer` measures a code block by its line count, on the premise
                // that it does not wrap. Left to wrap, a card is drawn taller than the row it was
                // given and the overflow is simply cut off, so an expanded card shows part of its
                // output and no way to reach the rest.
                CodeBlockScrollView(code: code, highlights: highlightsByBlockIndex[index] ?? []) {
                    coloredText(for: code, highlights: highlightsByBlockIndex[index] ?? [])
                }
            } else {
                MarkdownContentView(blocks: [block], highlights: [0: highlightsByBlockIndex[index] ?? []])
            }
        }
    }

    /// Builds the body as one `AttributedString` rather than concatenated `Text` pieces — a
    /// search highlight needs a background colour on an arbitrary sub-range, and only
    /// `Text(AttributedString)` can carry one without inserting anything into the text (see
    /// ``TranscriptSearchPainting``'s own doc comment for why that property matters). Per-line
    /// recolouring from `colorHint` sets only *foreground*, so a highlight's background paints
    /// over it without erasing which line is a command versus a diff addition or removal.
    private func coloredText(for code: String, highlights: [TranscriptHighlightSpan]) -> Text {
        var attributed = AttributedString(code)
        attributed.font = PaiTypography.markdownCodeBlock.font
        attributed.foregroundColor = PaiPalette.Semantic.textPrimary

        if let colorHint {
            let rawLines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var lineRanges: [NSRange] = []
            var cursor = 0
            for line in rawLines {
                let length = line.utf16.count
                let lineRange = NSRange(location: cursor, length: length)
                lineRanges.append(lineRange)
                cursor += length + 1  // +1 for the "\n" this split consumed between lines
                guard length > 0,
                    let range = TranscriptTextHighlighting.attributedRange(lineRange, source: code, in: attributed)
                else { continue }
                attributed[range].foregroundColor = colorHint.color(forLine: line)
            }

            if colorHint == .diff {
                applyWordLevelDiffHighlight(
                    rawLines: rawLines, lineRanges: lineRanges, code: code, colorHint: colorHint, into: &attributed)
            }
        }

        TranscriptTextHighlighting.apply(highlights, to: &attributed, source: code)
        return Text(attributed)
    }

    /// The word-level pass inside a changed line — `EditDiff.changedLinePairs` finds a removed
    /// line immediately followed by the added line it turned into, and this tints only the
    /// tokens that actually differ within that pair, on top of the whole-line colouring above.
    /// Background colour only, applied as a text attribute over the same characters already
    /// there: it never changes the text or its length, so it can never move a row's measured
    /// height, which is computed from the string's own line count rather than from how any of
    /// it is painted.
    private func applyWordLevelDiffHighlight(
        rawLines: [String], lineRanges: [NSRange], code: String, colorHint: ToolBodyColorHint,
        into attributed: inout AttributedString
    ) {
        // `EditDiff.changedLinePairs` only needs to know which lines are removed/added — the
        // literal `- `/`+ ` prefix `displayText(of:)` wrote is what carries that here, decoded
        // back rather than threaded through as a second argument.
        let diffLines: [EditDiff.Line] = rawLines.map { line in
            if line.hasPrefix("- ") { return .removed(String(line.dropFirst(2))) }
            if line.hasPrefix("+ ") { return .added(String(line.dropFirst(2))) }
            return .context(line)
        }
        for pair in EditDiff.changedLinePairs(in: diffLines) {
            guard case .removed(let removedText) = diffLines[pair.removedIndex],
                case .added(let addedText) = diffLines[pair.addedIndex]
            else { continue }
            let wordDiff = EditDiff.wordDiff(removed: removedText, added: addedText)
            highlightChangedTokens(
                wordDiff.removed, prefixedLine: rawLines[pair.removedIndex], lineRange: lineRanges[pair.removedIndex],
                code: code, colorHint: colorHint, into: &attributed)
            highlightChangedTokens(
                wordDiff.added, prefixedLine: rawLines[pair.addedIndex], lineRange: lineRanges[pair.addedIndex],
                code: code, colorHint: colorHint, into: &attributed)
        }
    }

    private func highlightChangedTokens(
        _ tokens: [EditDiff.WordToken], prefixedLine: String, lineRange: NSRange, code: String,
        colorHint: ToolBodyColorHint, into attributed: inout AttributedString
    ) {
        // Every line `EditDiff.lines` can pair carries exactly a two-character `- `/`+ ` prefix
        // (`displayText(of:)`'s own construction) ahead of the text `wordDiff` tokenized.
        var offset = lineRange.location + 2
        for token in tokens {
            let length = token.text.utf16.count
            defer { offset += length }
            guard token.changed, length > 0,
                let range = TranscriptTextHighlighting.attributedRange(
                    NSRange(location: offset, length: length), source: code, in: attributed)
            else { continue }
            attributed[range].backgroundColor = colorHint.color(forLine: prefixedLine).opacity(0.28)
        }
    }
}

enum ToolBodyColorHint: Equatable {
    case bashCommand
    case diff

    func color(forLine line: String) -> Color {
        switch self {
        case .bashCommand:
            return line.hasPrefix("$ ") ? PaiPalette.green500 : PaiPalette.Semantic.textPrimary
        case .diff:
            if line.hasPrefix("- ") { return PaiPalette.red500 }
            if line.hasPrefix("+ ") { return PaiPalette.green500 }
            return PaiPalette.Semantic.textPrimary
        }
    }
}

/// A plain prompt Freddy (or a device on his behalf) typed — right-aligned, filled, plain text,
/// tucked into ``ownBubbleTail`` with a fixed gutter (``TranscriptRowMetrics/bubbleGutter``)
/// so a long message stops short of the row's own left edge instead of going flush across it —
/// the gutter is what tells the eye whose message it is.
struct UserBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let attachmentPaths: [String]
    let sessionID: String
    let apiClient: PaiApiClient
    var highlights: [TranscriptHighlightSpan] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: TranscriptRowMetrics.attachmentChipSpacing) {
            if !text.isEmpty {
                TranscriptTextHighlighting.plainText(text, font: PaiTypography.body.font, highlights: highlights)
                    .foregroundStyle(.white)
                    .padding(.horizontal, TranscriptRowMetrics.bubbleHorizontalPadding)
                    .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
                    .background(
                        bubbleFill(light: PaiPalette.primary500, dark: PaiPalette.primary600, colorScheme: colorScheme),
                        in: .ownBubbleTail)
            }
            // Freddy's own file, already known to him — no confirmation before it is fetched,
            // unlike a `pai-file:` marker (see `AssistantProseView`).
            ForEach(attachmentPaths, id: \.self) { path in
                SessionAttachmentChipView(
                    sessionID: sessionID, apiClient: apiClient, path: path, requiresConfirmation: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, TranscriptRowMetrics.bubbleGutter)
    }
}

/// A genuine prompt relayed from another session — drawn like Freddy's own bubble but a different
/// colour (``PaiPalette/relay500``/``relay600``, mirroring `pai-cloud`'s `--color-relay-500/600`
/// exactly, not the closest named green), so a reader can tell it was not him.
struct RelayedBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let sender: String
    let group: String?
    var highlights: [TranscriptHighlightSpan] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: TranscriptRowMetrics.bubbleLabelSpacing) {
            Text(group.map { "\(sender) · \($0)" } ?? sender)
                .font(PaiTypography.captionEmphasized.font)
                .foregroundStyle(.white.opacity(0.85))
                .frame(height: TranscriptRowMetrics.bubbleLabelLineHeight, alignment: .leading)
            if !text.isEmpty {
                TranscriptTextHighlighting.plainText(text, font: PaiTypography.body.font, highlights: highlights)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, TranscriptRowMetrics.bubbleHorizontalPadding)
        .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
        .background(
            bubbleFill(light: PaiPalette.relay500, dark: PaiPalette.relay600, colorScheme: colorScheme),
            in: .ownBubbleTail
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, TranscriptRowMetrics.bubbleGutter)
    }
}

/// The second copy of a prompt Freddy sent, resent after an interrupt cut off the first — his own
/// bubble at 70% opacity (mirroring the web's `bg-primary-500/70`), with a small "Resent" pill
/// above the text carrying the same rotate glyph the web draws (`RotateCcw`, matched here by
/// `arrow.counterclockwise`). The pill only exists when there is text to caption, same as the
/// web's own `{text && (…)}` — an attachment-only resend draws exactly like a plain attachment-only
/// send, with no bubble or label at all. `TranscriptRowLayout`'s `.resentUserBubble` case mirrors
/// this precisely: a number that moves here and not there is a row drawn taller than its cell.
struct ResentBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let attachmentPaths: [String]
    let sessionID: String
    let apiClient: PaiApiClient
    var highlights: [TranscriptHighlightSpan] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: TranscriptRowMetrics.attachmentChipSpacing) {
            if !text.isEmpty {
                VStack(alignment: .trailing, spacing: TranscriptRowMetrics.bubbleLabelSpacing) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Resent")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 6)
                    // Pinned to the label's own line height rather than letting the pill's
                    // padding add to it — the pill is purely a horizontal decoration, so the
                    // vertical budget `TranscriptRowLayout` already reserves for a bubble's label
                    // line never has to change to fit it.
                    .frame(height: TranscriptRowMetrics.bubbleLabelLineHeight)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))

                    TranscriptTextHighlighting.plainText(text, font: PaiTypography.body.font, highlights: highlights)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, TranscriptRowMetrics.bubbleHorizontalPadding)
                .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
                .background(
                    bubbleFill(light: PaiPalette.primary500, dark: PaiPalette.primary600, colorScheme: colorScheme)
                        .opacity(0.7),
                    in: .ownBubbleTail
                )
            }
            ForEach(attachmentPaths, id: \.self) { path in
                SessionAttachmentChipView(
                    sessionID: sessionID, apiClient: apiClient, path: path, requiresConfirmation: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, TranscriptRowMetrics.bubbleGutter)
    }
}

/// An assistant's own reply — left-aligned, rendered as real markdown (unlike every other card,
/// which shows plain or lightly-coloured monospace), in the mirror of Freddy's own bubble: the
/// web's `bg-surface-100 dark:bg-surface-800` on `rounded-2xl rounded-bl-md`, which is the pairing
/// ``PaiPalette/Semantic/raisedSurface`` carries. The two sides of the conversation read as a
/// conversation, and the tool cards around them stay visibly a different kind of thing —
/// bordered rather than filled.
///
/// `TranscriptRowLayout`'s own `assistantBubble` case mirrors the padding and the gutter exactly;
/// a number that moves here and not there is a row drawn taller than the cell it was given.
struct AssistantProseView: View {
    let blocks: [MarkdownBlock]
    /// Every `pai-file:` marker path in this reply — the message itself is never rewritten to
    /// remove the marker line, so `blocks` already renders it as ordinary text; these chips are
    /// purely an addition below it, per Freddy's own rule (see `MessageRouting.extractFilePaths`).
    let filePaths: [String]
    let sessionID: String
    let apiClient: PaiApiClient
    var highlights: [Int: [TranscriptHighlightSpan]] = [:]

    var body: some View {
        // No bubble, no gutter and no padding of its own: `ProseRowView` owns this row's whole
        // geometry, and `TranscriptRowLayout` measured the text at exactly the width that row
        // leaves. Anything added here narrows what the text wraps at without narrowing what was
        // measured, which is a row drawn taller than the cell it was given.
        //
        // The shape mirrors `UserBubbleView`: content first, one fixed-height chip per marker
        // after it, the same spacing constant — a number that moves in one and not the other is
        // the same disagreement from the other side.
        VStack(alignment: .leading, spacing: TranscriptRowMetrics.attachmentChipSpacing) {
            MarkdownContentView(blocks: blocks, highlights: highlights)
            // An agent-offered file, never the reader's own — a non-image confirms before
            // anything is fetched (see `SessionAttachmentChipView`).
            ForEach(filePaths, id: \.self) { path in
                SessionAttachmentChipView(
                    sessionID: sessionID, apiClient: apiClient, path: path, requiresConfirmation: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A slash command Freddy typed. With arguments, they render unconditionally in his own bubble —
/// a reader must never click to see their own words. With none, a compact, non-interactive line.
struct CommandCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    let args: String?
    var highlights: [TranscriptHighlightSpan] = []

    var body: some View {
        if let args {
            VStack(alignment: .trailing, spacing: TranscriptRowMetrics.bubbleLabelSpacing) {
                Text(name)
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(height: TranscriptRowMetrics.bubbleLabelLineHeight, alignment: .leading)
                TranscriptTextHighlighting.plainText(args, font: PaiTypography.body.font, highlights: highlights)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, TranscriptRowMetrics.bubbleHorizontalPadding)
            .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
            .background(
                bubbleFill(light: PaiPalette.primary500, dark: PaiPalette.primary600, colorScheme: colorScheme),
                in: .ownBubbleTail
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, TranscriptRowMetrics.bubbleGutter)
        } else {
            // Still Freddy's own message, just with nothing to show for its arguments — the
            // trailing, primary-coloured identity every other bubble of his gets, not the
            // left-aligned muted chrome a system row draws. Pinned to the same label line the
            // layout budgets for this case, so the row this card measures for is the row it draws.
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                Text(name)
            }
            .font(PaiTypography.captionEmphasized.font)
            .foregroundStyle(.white)
            .padding(.horizontal, TranscriptRowMetrics.bubbleHorizontalPadding / 2)
            .padding(.vertical, 4)
            .background(
                bubbleFill(light: PaiPalette.primary500, dark: PaiPalette.primary600, colorScheme: colorScheme),
                in: .ownBubbleTail
            )
            .frame(
                height: TranscriptRowMetrics.bubbleLabelLineHeight + TranscriptRowMetrics.bubbleVerticalPadding,
                alignment: .trailing
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, TranscriptRowMetrics.bubbleGutter)
        }
    }
}

/// Renders parsed markdown blocks. Recurses for `.blockQuote`/`.list`: each nested
/// `MarkdownContentView` narrows by exactly the inset its own `HStack` (a block quote's rule, a
/// list item's marker) reserves, and `TextKitBlockMeasurer` mirrors that same narrowing through
/// `NestedBlockLayout` rather than measuring the nested content flattened at the outer width.
///
/// `highlights` is keyed by index into `blocks` — meaningful only at the top level a card's own
/// plan indexes against (see `TranscriptSearchIndex`'s doc comment). A recursive call for a
/// nested list item or blockquote passes none: a hit's `blockIndex` names a position in the
/// *card's* flat block list, which does not correspond to a position inside a block nested
/// several levels down, so a hit inside a list or a blockquote still opens and scrolls to the
/// right row but is not painted character-for-character inside it.
struct MarkdownContentView: View {
    let blocks: [MarkdownBlock]
    var highlights: [Int: [TranscriptHighlightSpan]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptContentMetrics.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, highlights: highlights[index] ?? [])
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, highlights: [TranscriptHighlightSpan]) -> some View {
        switch block {
        case .paragraph(let text):
            styledText(text, style: PaiTypography.markdownBody, highlights: highlights)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            styledText(text, style: headingStyle(level), highlights: highlights)
                .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(_, let code):
            // Scrolls sideways rather than wrapping, matching the web's `overflow-x-auto` on
            // every `<pre>`. Wrapped, a long line reflows into a shape that is not the code any
            // more; cut off, most lines of most code are unreadable on a phone.
            //
            // 🚨 The height this draws to must equal what `MarkdownCodeBlockLayout` measures, or
            // every row above the reader moves when this one lays out. That is why the text is
            // pinned to a line-count height here rather than left to size itself: two independent
            // answers to "how tall is this" is exactly the disagreement the transcript's
            // precomputed layout cannot absorb.
            CodeBlockScrollView(code: code, highlights: highlights) {
                TranscriptTextHighlighting.plainText(
                    code, font: PaiTypography.markdownCodeBlock.font, highlights: highlights
                )
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
            }

        case .preformattedText(let text):
            // The transcript's own Thinking card — Claude's raw reasoning, not code, so it wraps
            // like ordinary prose instead of scrolling sideways the way `.codeBlock` above does:
            // matches the web's `whitespace-pre-wrap break-all` `<pre>`. `LongTokenSoftBreaker`
            // stands in for CSS `break-all` (`Text` has no supported way to break mid-word on its
            // own — see that type's own doc comment), and every highlight range has to be
            // remapped onto the same soft-broken string or a hit would paint a few characters
            // off. `TextKitBlockMeasurer`'s own `.preformattedText` case measures the identical
            // soft-broken string, which is what keeps this in step with the row height the
            // transcript already precomputed for it.
            let (softBroken, insertions) = LongTokenSoftBreaker.apply(to: text)
            let remappedHighlights = highlights.map { span in
                (range: LongTokenSoftBreaker.remap(span.range, insertionOffsets: insertions), isCurrent: span.isCurrent)
            }
            TranscriptTextHighlighting.plainText(
                softBroken, font: PaiTypography.markdownCodeBlock.font, highlights: remappedHighlights
            )
            .foregroundStyle(PaiPalette.Semantic.textPrimary)
            .fixedSize(horizontal: false, vertical: true)

        case .blockQuote(let nested):
            HStack(spacing: TranscriptRowMetrics.blockQuoteSpacing) {
                Rectangle().fill(PaiPalette.Semantic.borderStrong).frame(
                    width: TranscriptRowMetrics.blockQuoteRuleWidth)
                MarkdownContentView(blocks: nested)
            }

        case .list(let list):
            VStack(alignment: .leading, spacing: TranscriptRowMetrics.listItemSpacing) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: TranscriptRowMetrics.listMarkerSpacing) {
                        Text(marker(for: list.marker, index: index, checkbox: item.checkbox))
                            .font(PaiTypography.markdownBody.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                        MarkdownContentView(blocks: item.blocks)
                    }
                }
            }

        case .table(let table):
            GfmTableView(table: table)

        case .thematicBreak:
            Divider()

        case .htmlBlock(let raw):
            TranscriptTextHighlighting.plainText(
                raw, font: PaiTypography.markdownCodeBlock.font, highlights: highlights
            )
            .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
    }

    private func marker(for marker: MarkdownList.Marker, index: Int, checkbox: MarkdownListItem.Checkbox?) -> String {
        if let checkbox {
            return checkbox == .checked ? "☑" : "☐"
        }
        switch marker {
        case .bullet: return "•"
        case .ordered(let start): return "\(Int(start) + index)."
        }
    }

    private func headingStyle(_ level: Int) -> PaiTypography.Style {
        switch level {
        case 1: return PaiTypography.markdownHeading1
        case 2: return PaiTypography.markdownHeading2
        case 3: return PaiTypography.markdownHeading3
        default: return PaiTypography.markdownHeading4
        }
    }

    /// Links are coloured but not yet tappable — a deliberate cut, not an oversight.
    ///
    /// Built as one `AttributedString` covering the whole paragraph rather than concatenated
    /// `Text` runs — a search highlight needs a background colour over an arbitrary sub-range,
    /// which only `Text(AttributedString)` can carry without inserting anything into the text.
    /// `InlinePresentationIntent` stands in for `.bold()`/`.italic()`: it is the same mechanism
    /// `Text(AttributedString(markdown:))` itself uses to render emphasis, so it needs no font
    /// substitution and cannot disagree with what `TextKitBlockMeasurer` already measured this
    /// same run at.
    private func styledText(_ inline: InlineText, style: PaiTypography.Style, highlights: [TranscriptHighlightSpan])
        -> Text
    {
        let source = inline.plainText
        var attributed = AttributedString(source)
        attributed.font = style.font

        var cursor = 0
        for run in inline.runs {
            let length = run.text.utf16.count
            defer { cursor += length }
            guard length > 0,
                let range = TranscriptTextHighlighting.attributedRange(
                    NSRange(location: cursor, length: length), source: source, in: attributed)
            else { continue }

            if run.style.contains(.code) {
                attributed[range].font = PaiTypography.markdownInlineCode.font
            }
            var intent: InlinePresentationIntent = []
            if run.style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if run.style.contains(.italic) { intent.insert(.emphasized) }
            if !intent.isEmpty { attributed[range].inlinePresentationIntent = intent }
            if run.style.contains(.strikethrough) { attributed[range].strikethroughStyle = .single }
            if let destination = run.destination {
                attributed[range].foregroundColor = PaiPalette.Semantic.accentText
                attributed[range].underlineStyle = .single
                // Colour alone only makes it look like a link. `Text` renders a run as tappable
                // when it carries a real `link` attribute and not otherwise, so without this a
                // reader gets the affordance and nothing behind it — including a note's own
                // `[[wikilink]]`, whose whole point is going somewhere.
                //
                // A destination that is not a valid URL is left as plain styled text rather than
                // being coerced into one: a broken link that does nothing is better than one that
                // opens something arbitrary.
                if let url = URL(string: destination) {
                    attributed[range].link = url
                }
            }
        }

        TranscriptTextHighlighting.apply(highlights, to: &attributed, source: source)
        return Text(attributed)
    }
}

/// A GFM table, its own horizontally-scrolling grid — matching the web, a cell never wraps, so a
/// wide table scrolls instead of being cut off with nothing to reach the rest of it.
///
/// A hit inside a cell still opens and scrolls to the row (the store-side index covers it) — it
/// is just not painted inside the cell, the one scope cut `MarkdownContentView`'s own doc comment
/// names, since a cell here is a single flat `Text` with no run-splitting machinery at all.
struct GfmTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: TranscriptRowMetrics.tableRowSpacing) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                        Text(cell.plainText)
                            .font(PaiTypography.bodyEmphasized.font)
                            .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell.plainText)
                                .font(PaiTypography.markdownBody.font)
                                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        }
                    }
                }
            }
        }
    }
}

/// Shared plumbing for painting a search highlight over an `AttributedString` without changing
/// what it measures as — see ``TranscriptSearchPainting``'s own doc comment for the constraint
/// this exists to serve. Every rendering function above that can carry a highlight goes through
/// this, so there is exactly one place that converts a UTF-16 ``NSRange`` into an
/// `AttributedString` sub-range and exactly one place that decides what a hit looks like painted.
enum TranscriptTextHighlighting {
    /// A plain, unstyled run of text with no per-character formatting of its own — a bubble's
    /// body, a code block, raw HTML source. `font` is the one attribute this always sets; a
    /// caller applying its own colour via an outer `.foregroundStyle()` still wins wherever a
    /// highlight has not overridden it, since this leaves no foreground attribute of its own in
    /// the unhighlighted stretches.
    static func plainText(_ text: String, font: Font, highlights: [TranscriptHighlightSpan]) -> Text {
        var attributed = AttributedString(text)
        attributed.font = font
        apply(highlights, to: &attributed, source: text)
        return Text(attributed)
    }

    /// Converts a UTF-16 `NSRange` measured against `source` into the equivalent sub-range of
    /// `attributed` — valid whenever `attributed`'s characters are `source`'s characters in the
    /// same order, which every caller here guarantees by building `attributed` directly from
    /// `source` before calling this.
    static func attributedRange(_ nsRange: NSRange, source: String, in attributed: AttributedString)
        -> Range<AttributedString.Index>?
    {
        guard let range = Range(nsRange, in: source) else { return nil }
        guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed)
        else { return nil }
        return lower..<upper
    }

    /// Paints every highlight onto `attributed` as a background colour (and, for the current hit,
    /// a foreground colour too, for contrast against its brighter background) — never anything
    /// that could change what a width this text was already measured at wraps to.
    static func apply(_ highlights: [TranscriptHighlightSpan], to attributed: inout AttributedString, source: String) {
        guard !highlights.isEmpty else { return }
        let segments = TranscriptSearchPainting.segments(length: source.utf16.count, highlights: highlights)
        for segment in segments where segment.emphasis != .none {
            guard let range = attributedRange(segment.range, source: source, in: attributed) else { continue }
            switch segment.emphasis {
            case .none:
                break
            case .hit:
                attributed[range].backgroundColor = PaiPalette.SearchHighlight.allHits
            case .currentHit:
                attributed[range].backgroundColor = PaiPalette.SearchHighlight.currentBackground
                attributed[range].foregroundColor = PaiPalette.SearchHighlight.currentForeground
            }
        }
    }
}
