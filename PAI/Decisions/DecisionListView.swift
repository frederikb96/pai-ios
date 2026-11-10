import PAIKit
import SwiftUI

/// One session's open decisions, each a single line — its number, what a yes sets in motion and
/// the recommendation — that opens to its context and the answers it offers. A tap picks an
/// answer without sending it. Under a transcript the bar below adds every pick to the message in
/// the composer, to be sent with whatever else the owner writes or records, and the server marks a
/// decision answered when a message carries its line; the Decisions app has no composer, so there
/// (`sendDirectly`) Send turns the picks into one message of their own. Shared by the pin above a
/// transcript and the Decisions app. Swift port of `DecisionList.tsx`. The picks are the
/// session's (`DecisionsStore.picks`), shared with the cards inside its replies, so the bar here
/// takes what was picked there too; what this list holds for itself is `DecisionListState`.
struct DecisionListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var state = DecisionListState()
    @State private var dismissing: Decision?
    @FocusState private var focusedOwnWords: Int?

    let sessionId: String
    let decisions: [Decision]
    /// Send the answers as a message of their own, where no composer is shown.
    var sendDirectly = false
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
        let otherChosen = store.map { state.isOtherChosen(decision, store: $0) } ?? false
        VStack(alignment: .leading, spacing: 10) {
            if !decision.context.isEmpty {
                MarkdownContentView(blocks: MarkdownParser.parse(decision.context))
            }
            NoteInlineFlowLayout {
                ForEach(decision.options, id: \.self) { option in
                    optionButton(
                        option + (decision.isRecommended(option) ? " (recommended)" : ""),
                        selected: choice == option
                    ) {
                        guard let store else { return }
                        state.choose(option, for: decision, store: store)
                    }
                }
                optionButton("Other…", selected: otherChosen, dashed: true) {
                    guard let store else { return }
                    state.toggleOther(decision, store: store)
                    if state.writing.contains(decision.number) { focusedOwnWords = decision.number }
                }
                optionButton("Dismiss", selected: false, muted: true) { dismissing = decision }
                    .accessibilityIdentifier("decision-dismiss-\(decision.number)")
            }
            if otherChosen { ownWordsField(decision) }
        }
    }

    private func ownWordsBinding(_ decision: Decision) -> Binding<String> {
        Binding(
            get: {
                guard let store else { return "" }
                return state.ownWordsText(for: decision, store: store)
            },
            set: { text in
                guard let store else { return }
                state.setOwnWords(text, for: decision, store: store)
            })
    }

    /// Other… is an answer like the options, so what is typed is the pick as it stands: there is
    /// nothing to confirm.
    private func ownWordsField(_ decision: Decision) -> some View {
        TextField("Your answer to D\(decision.number)", text: ownWordsBinding(decision), axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .focused($focusedOwnWords, equals: decision.number)
            .accessibilityIdentifier("decision-own-words")
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

    private func barLabel(pendingCount: Int) -> String {
        let noun = pendingCount == 1 ? "answer" : "\(pendingCount) answers"
        if sendDirectly { return state.isSending ? "Sending…" : "Send \(noun)" }
        return "Add \(noun) to message"
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
                            if sendDirectly {
                                Task { await state.send(sessionId: sessionId, store: store) }
                            } else if let drafts = environment.connection?.drafts {
                                store.addPicksToMessage(sessionId: sessionId, drafts: drafts)
                            }
                        } label: {
                            Text(barLabel(pendingCount: pending.count))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isSending)
                        .accessibilityIdentifier(sendDirectly ? "decision-send" : "decision-add-to-message")
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
