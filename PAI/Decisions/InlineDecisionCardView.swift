import PAIKit
import SwiftUI

/// What a decision card inside a reply can ask the transcript to do. The card lives in a
/// collection-view cell, so anything that opens a prompt or sends a request goes through the
/// controller, which owns the session's store and re-measures the row when the answer lands.
struct InlineDecisionActions {
    /// Pick an answer without sending it, or take back the one already picked.
    let pick: @MainActor (Decision, String) -> Void
    /// Ask for the owner's own words in a prompt, then pick them; where they are already the pick,
    /// the prompt starts from them and can take them back.
    let ownWords: @MainActor (Decision) -> Void
    /// Withdraw one answered in the conversation, after a confirmation.
    let dismiss: @MainActor (Decision) -> Void
    /// Add every answer picked for the session to the composer's message.
    let addToMessage: @MainActor () -> Void
    let clearPicks: @MainActor () -> Void
    /// Open a resolved decision's full card again, or close it back to its line.
    let toggleReopened: @MainActor (Int) -> Void
}

/// One decision where a reply embeds it, or where an unembedded one is placed: while open, the
/// card the pin opens to (title, recommendation, context, its answers, Other…, Dismiss, Add to
/// message), answered through the session's shared picks; once resolved, one line with its answer or that
/// it was withdrawn, which a tap opens to the read-only card and closes again; for a guest or a
/// number the session never had, the marker text. Swift port of the web's `InlineDecision.tsx`.
///
/// Every section is pinned to the height `InlineDecisionLayout` measured for it, and every text is
/// drawn by the transcript's own markdown view, which the measurer mirrors, so the card is exactly
/// as tall as the row reserved for it.
struct InlineDecisionCardView: View {
    let decision: MeasuredDecision
    let actions: InlineDecisionActions?

    var body: some View {
        Group {
            switch decision.display {
            case .loading:
                EmptyView()
            case .marker(let number):
                MarkdownContentView(blocks: [InlineDecisionLayout.markerBlock(number: number)])
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .resolved(let number, let title, let answer):
                resolved(number: number, title: title, answer: answer)
            case .reopened(let reopened):
                ReopenedDecisionCard(decision: reopened, measured: decision.measured, actions: actions)
            case .open(let open):
                OpenDecisionCard(open: open, measured: decision.measured, actions: actions)
            }
        }
        .frame(height: decision.measured.height, alignment: .top)
    }

    private func resolved(number: Int, title: String, answer: String?) -> some View {
        Button {
            actions?.toggleReopened(number)
        } label: {
            MarkdownContentView(
                blocks: [InlineDecisionLayout.resolvedBlock(number: number, title: title, answer: answer)]
            )
            .foregroundStyle(PaiPalette.Semantic.textSecondary)
            .padding(.horizontal, InlineDecisionLayout.cardHorizontalPadding)
            .padding(.vertical, InlineDecisionLayout.resolvedVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PaiPalette.Semantic.borderDefault))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the whole decision")
        .accessibilityIdentifier("inline-decision-\(number)")
    }
}

/// A resolved decision opened again: its line, which closes it, then what the open card said —
/// recommendation, context, the options with the answered one marked — with nothing to press.
private struct ReopenedDecisionCard: View {
    let decision: Decision
    let measured: InlineDecisionLayout.Measured
    let actions: InlineDecisionActions?

    var body: some View {
        VStack(alignment: .leading, spacing: InlineDecisionLayout.sectionSpacing) {
            section(measured.title) {
                Button {
                    actions?.toggleReopened(decision.number)
                } label: {
                    MarkdownContentView(
                        blocks: [
                            InlineDecisionLayout.resolvedBlock(
                                number: decision.number, title: decision.title,
                                answer: InlineDecisionLayout.resolvedAnswer(decision))
                        ]
                    )
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows only the answer")
            }
            if measured.recommendation > 0 {
                section(measured.recommendation) {
                    MarkdownContentView(blocks: [InlineDecisionLayout.recommendationBlock(decision)])
                        .foregroundStyle(PaiPalette.Semantic.accentText)
                }
            }
            if measured.context > 0 {
                section(measured.context) {
                    MarkdownContentView(blocks: InlineDecisionLayout.contextBlocks(decision))
                }
            }
            // Left out when there are no options, as the measurement leaves out its gap.
            if !measured.answerRows.isEmpty { optionGrid }
        }
        .foregroundStyle(PaiPalette.Semantic.textPrimary)
        .padding(.horizontal, InlineDecisionLayout.cardHorizontalPadding)
        .padding(.vertical, InlineDecisionLayout.resolvedVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PaiPalette.Semantic.borderDefault))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inline-decision-\(decision.number)")
    }

    private func section(_ height: Double, @ViewBuilder content: () -> some View) -> some View {
        content().frame(maxWidth: .infinity, alignment: .topLeading).frame(height: height, alignment: .top)
    }

    /// The options in the open card's grid, each row pinned to its measured height.
    private var optionGrid: some View {
        let answers = InlineDecisionLayout.reopenedAnswers(decision)
        let columns = InlineDecisionLayout.optionColumns
        let rows: [[InlineDecisionLayout.Answer]] = stride(from: 0, to: answers.count, by: columns).map {
            Array(answers[$0..<min($0 + columns, answers.count)])
        }
        return VStack(spacing: InlineDecisionLayout.optionRowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: InlineDecisionLayout.optionColumnSpacing) {
                    ForEach(row, id: \.self) { answer in option(answer) }
                    ForEach(row.count..<columns, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .frame(height: measured.answerRows.indices.contains(index) ? measured.answerRows[index] : 0)
            }
        }
    }

    private func option(_ answer: InlineDecisionLayout.Answer) -> some View {
        let chosen: Bool
        if case .option(let text) = answer, decision.state == .answered, decision.answer == text {
            chosen = true
        } else {
            chosen = false
        }
        let border: Color = chosen ? PaiPalette.primary500 : PaiPalette.Semantic.borderDefault
        return MarkdownContentView(
            blocks: [
                .paragraph(InlineText(runs: [InlineRun(text: InlineDecisionLayout.label(of: answer, in: decision))]))
            ]
        )
        .foregroundStyle(chosen ? PaiPalette.Semantic.textPrimary : PaiPalette.Semantic.textSecondary)
        .padding(.horizontal, InlineDecisionLayout.optionHorizontalPadding)
        .padding(.vertical, InlineDecisionLayout.optionVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: chosen ? 2 : 1))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

private struct OpenDecisionCard: View {
    let open: InlineOpenDecision
    let measured: InlineDecisionLayout.Measured
    let actions: InlineDecisionActions?

    private var decision: Decision { open.decision }

    var body: some View {
        VStack(alignment: .leading, spacing: InlineDecisionLayout.sectionSpacing) {
            if measured.title > 0 {
                section(measured.title) {
                    MarkdownContentView(
                        blocks: [InlineDecisionLayout.titleBlock(number: decision.number, title: decision.title)])
                }
            }
            if measured.recommendation > 0 {
                section(measured.recommendation) {
                    MarkdownContentView(blocks: [InlineDecisionLayout.recommendationBlock(decision)])
                        .foregroundStyle(PaiPalette.Semantic.accentText)
                }
            }
            if measured.chips > 0 {
                section(measured.chips) { chips }
            }
            if measured.context > 0 {
                section(measured.context) {
                    MarkdownContentView(blocks: InlineDecisionLayout.contextBlocks(decision))
                }
            }
            answerGrid
            if measured.sendBar > 0 {
                section(measured.sendBar) { sendBar }
            }
            if measured.error > 0, let message = open.errorMessage {
                section(measured.error) {
                    MarkdownContentView(blocks: [InlineDecisionLayout.errorBlock(message)])
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
                .accessibilityIdentifier("inline-decision-error-\(decision.number)")
            }
        }
        .foregroundStyle(PaiPalette.Semantic.textPrimary)
        .padding(.horizontal, InlineDecisionLayout.cardHorizontalPadding)
        .padding(.vertical, InlineDecisionLayout.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BannerTone.accent.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BannerTone.accent.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inline-decision-\(decision.number)")
    }

    private func section(_ height: Double, @ViewBuilder content: () -> some View) -> some View {
        content().frame(maxWidth: .infinity, alignment: .topLeading).frame(height: height, alignment: .top)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if decision.blocks { chip("blocks", tone: .red) }
            if let picked = open.picked { chip("Picked: \(picked)", tone: .accent) }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, tone: BannerTone) -> some View {
        Text(text)
            .font(PaiTypography.caption.font)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, InlineDecisionLayout.chipVerticalPadding)
            .foregroundStyle(tone.titleColor)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tone.border))
    }

    /// The answers in rows of ``InlineDecisionLayout/optionColumns``, each row pinned to its
    /// measured height so every button in it is as tall as the tallest label.
    private var answerGrid: some View {
        let answers = InlineDecisionLayout.answers(decision)
        let columns = InlineDecisionLayout.optionColumns
        let rows: [[InlineDecisionLayout.Answer]] = stride(from: 0, to: answers.count, by: columns).map {
            Array(answers[$0..<min($0 + columns, answers.count)])
        }
        return VStack(spacing: InlineDecisionLayout.optionRowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: InlineDecisionLayout.optionColumnSpacing) {
                    ForEach(row, id: \.self) { answer in answerButton(answer) }
                    ForEach(row.count..<columns, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .frame(height: measured.answerRows.indices.contains(index) ? measured.answerRows[index] : 0)
            }
        }
    }

    private func answerButton(_ answer: InlineDecisionLayout.Answer) -> some View {
        let selected: Bool
        let dashed: Bool
        let muted: Bool
        switch answer {
        case .option(let option):
            selected = open.picked == option
            dashed = false
            muted = false
        case .ownWords:
            selected = open.picked.map { !decision.options.contains($0) } ?? false
            dashed = true
            muted = false
        case .dismiss:
            selected = false
            dashed = false
            muted = true
        }
        let label = InlineDecisionLayout.label(of: answer, in: decision)
        let foreground: Color =
            selected ? .white : muted ? PaiPalette.Semantic.textSecondary : PaiPalette.Semantic.textPrimary
        let border: Color =
            selected
            ? PaiPalette.primary500 : muted ? PaiPalette.Semantic.borderDefault : PaiPalette.Semantic.borderStrong
        return Button {
            switch answer {
            case .option(let option): actions?.pick(decision, option)
            case .ownWords: actions?.ownWords(decision)
            case .dismiss: actions?.dismiss(decision)
            }
        } label: {
            MarkdownContentView(blocks: [.paragraph(InlineText(runs: [InlineRun(text: label)]))])
                .foregroundStyle(foreground)
                .padding(.horizontal, InlineDecisionLayout.optionHorizontalPadding)
                .padding(.vertical, InlineDecisionLayout.optionVerticalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(selected ? PaiPalette.primary500 : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4] : []))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(actions == nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(accessibilityID(answer))
    }

    private func accessibilityID(_ answer: InlineDecisionLayout.Answer) -> String {
        switch answer {
        case .option(let option): "inline-decision-\(decision.number)-option-\(option)"
        case .ownWords: "inline-decision-\(decision.number)-own-words"
        case .dismiss: "inline-decision-\(decision.number)-dismiss"
        }
    }

    private var sendBar: some View {
        let label = open.pendingCount == 1 ? "Add answer to message" : "Add \(open.pendingCount) answers to message"
        return HStack(spacing: 8) {
            Button {
                actions?.addToMessage()
            } label: {
                Text(label)
                    .font(PaiTypography.markdownBody.font)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(maxHeight: .infinity)
                    .background(PaiPalette.primary500, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(open.isSending || actions == nil)
            .accessibilityIdentifier("inline-decision-\(decision.number)-add-to-message")
            Button {
                actions?.clearPicks()
            } label: {
                Text("Clear")
                    .font(PaiTypography.markdownBody.font)
                    .lineLimit(1)
                    .foregroundStyle(PaiPalette.Semantic.accentText)
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(open.isSending || actions == nil)
            Spacer(minLength: 0)
        }
    }
}
