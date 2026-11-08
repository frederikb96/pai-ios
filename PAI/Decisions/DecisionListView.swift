import PAIKit
import SwiftUI

/// One session's open decisions, each a single line — its number, what a yes sets in motion and
/// the recommendation — that opens to its context and the answers it offers. A tap picks an
/// answer without sending it; Send turns every pick into one message to the session, which marks
/// them answered. Shared by the pin above a transcript and the Decisions app. Swift port of
/// `DecisionList.tsx`. The picks are the session's (`DecisionsStore.picks`), shared with the cards
/// inside its replies, so Send here sends what was picked there too; what this list holds for
/// itself is `DecisionListState`.
struct DecisionListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var state = DecisionListState()
    @State private var dismissing: Decision?

    let sessionId: String
    let decisions: [Decision]
    /// Past this height the list scrolls inside itself; `nil` lays it out at its natural height.
    /// Both layouts read the one `state`, so a pick survives the list growing past the bound.
    var maxHeight: CGFloat?

    private var store: DecisionsStore? { environment.connection?.decisions }

    var body: some View {
        Group {
            if let maxHeight {
                ViewThatFits(in: .vertical) {
                    lines
                    ScrollView { lines }.frame(maxHeight: maxHeight)
                }
            } else {
                lines
            }
        }
        .confirmationDialog(
            "Dismiss D\(dismissing?.number ?? 0)?", isPresented: dismissBinding, titleVisibility: .visible,
            presenting: dismissing
        ) { decision in
            Button("Dismiss", role: .destructive) {
                guard let store else { return }
                Task { await state.withdraw(decision, store: store) }
            }
        } message: { _ in
            Text("Use this for a question you already answered in the conversation. The agent is not told anything.")
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(decisions) { decision in
                line(decision)
                if decision.id != decisions.last?.id { Divider() }
            }
            footer
        }
        .accessibilityIdentifier("decision-list")
    }

    private var dismissBinding: Binding<Bool> {
        Binding(get: { dismissing != nil }, set: { if !$0 { dismissing = nil } })
    }

    @ViewBuilder
    private func line(_ decision: Decision) -> some View {
        let isOpen = state.expanded.contains(decision.number)
        let choice = store?.picked(sessionId: sessionId, number: decision.number)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                state.toggleExpanded(decision.number)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("D\(decision.number)").font(PaiTypography.bodyEmphasized.font)
                    summary(decision)
                        .font(PaiTypography.body.font)
                        .lineLimit(isOpen ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if decision.blocks { chip("blocks", tone: .red) }
                    if let choice { chip(choice, tone: .accent).frame(maxWidth: 110) }
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("decision-line-\(decision.number)")
            if isOpen { details(decision, choice: choice) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func summary(_ decision: Decision) -> Text {
        let recommended = Text(" — Recommended: \(decision.recommendation)")
            .foregroundStyle(PaiPalette.Semantic.accentText)
        return Text(decision.title) + recommended
    }

    @ViewBuilder
    private func details(_ decision: Decision, choice: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !decision.context.isEmpty {
                MarkdownContentView(blocks: MarkdownParser.parse(decision.context))
            }
            NoteInlineFlowLayout {
                ForEach(decision.options, id: \.self) { option in
                    optionButton(
                        option + (decision.isRecommended(option) ? " (recommended)" : ""),
                        selected: choice == option
                    ) { store?.pick(option, for: decision) }
                }
                optionButton("Other…", selected: state.writing == decision.number, dashed: true) {
                    guard let store else { return }
                    state.toggleWriting(for: decision, store: store)
                }
                optionButton("Dismiss", selected: false, muted: true) { dismissing = decision }
                    .accessibilityIdentifier("decision-dismiss-\(decision.number)")
            }
            if state.writing == decision.number { ownWordsField(decision) }
        }
    }

    private func ownWordsField(_ decision: Decision) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Your answer to D\(decision.number)", text: $state.ownWords, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("decision-own-words")
            Button("Use") {
                guard let store else { return }
                state.commitOwnWords(for: decision, store: store)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.canUseOwnWords)
        }
    }

    /// `muted` is the quieter look of an action that sends nothing (Dismiss): same outlined shape as
    /// the answers, secondary text colour and the default border instead of the strong one.
    private func optionButton(
        _ label: String, selected: Bool, dashed: Bool = false, muted: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(PaiTypography.captionEmphasized.font)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(
                    selected
                        ? Color.white
                        : muted ? PaiPalette.Semantic.textSecondary : PaiPalette.Semantic.textPrimary
                )
                .background(selected ? PaiPalette.primary500 : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            selected
                                ? PaiPalette.primary500
                                : muted ? PaiPalette.Semantic.borderDefault : PaiPalette.Semantic.borderStrong,
                            style: StrokeStyle(lineWidth: 1, dash: dashed ? [4] : []))
                )
        }
        .buttonStyle(.plain)
    }

    private func chip(_ text: String, tone: BannerTone) -> some View {
        Text(text)
            .font(PaiTypography.caption.font)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(tone.titleColor)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tone.border))
    }

    @ViewBuilder
    private var footer: some View {
        let pending = store?.pendingAnswers(sessionId: sessionId) ?? []
        if !pending.isEmpty || decisions.count > 1 || state.errorMessage != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if !pending.isEmpty {
                        Button {
                            guard let store else { return }
                            Task { await state.send(sessionId: sessionId, store: store) }
                        } label: {
                            Text(
                                state.isSending
                                    ? "Sending…" : pending.count == 1 ? "Send answer" : "Send \(pending.count) answers")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isSending)
                        .accessibilityIdentifier("decision-send")
                        Button("Clear") { store?.clearPicks(sessionId: sessionId) }
                            .disabled(state.isSending)
                    } else if decisions.count > 1 {
                        Button("All as recommended") { store?.pickAllRecommended(decisions) }
                            .accessibilityIdentifier("decision-all-recommended")
                    }
                }
                .font(PaiTypography.captionEmphasized.font)
                if let message = state.errorMessage {
                    Text(message)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                        .accessibilityIdentifier("decision-error")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}
