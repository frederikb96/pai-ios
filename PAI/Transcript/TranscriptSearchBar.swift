import PAIKit
import SwiftUI

/// The transcript's find bar. Replaces the composer while a search is open, rather than
/// overlaying it — the same screen real estate, and the keyboard the reader is about to type into
/// is already anchored to the bottom, which is where Safari's own "Find on Page" puts its bar for
/// the same reason: a thumb reaches the bottom of the screen, not the navigation bar, and the
/// software keyboard is about to claim that space anyway.
///
/// Mutates ``TranscriptSearchState`` directly rather than through closures — every action here
/// (typing, picking a kind, stepping, closing) is a pure write that type already owns, and
/// `TranscriptCollectionViewController` observes the same shared instance to react: running
/// `find` when `query`/`kind` change, draining a stepping request, painting when the current hit
/// changes. Nothing here needs to know the collection view exists — see that type's own doc
/// comment for why a request/drain field, not a closure, is what carries an action needing the
/// network across to it.
struct TranscriptSearchBar: View {
    @Bindable var state: TranscriptSearchState

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                TextField(
                    state.kind.map { "Showing: \($0.label)" } ?? "Find in transcript", text: $state.query
                )
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.search)
                .onSubmit { state.requestNext() }
                // Typing is always a return to text search — the two modes are mutually
                // exclusive, and this is the more forgiving of the two ways out of kind mode
                // (the picker itself is the other).
                .onChange(of: state.query) { _, newValue in
                    guard !newValue.isEmpty, state.kind != nil else { return }
                    state.kind = nil
                }
                if state.loading {
                    ProgressView()
                        .controlSize(.small)
                } else if let summary = state.resultsSummary {
                    Text(summary)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .accessibilityIdentifier("transcript-search-summary")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 10))

            // Stepping through a KIND of message, not text — the same up/down/counter/close
            // chrome below, reused rather than duplicated in a second bar. Compact on a phone,
            // keyboard- and screen-reader-accessible for free — the native `<select>`'s own
            // reasoning on the web, ported to the closest SwiftUI equivalent.
            Menu {
                Button("Search text") {
                    state.kind = nil
                    if state.query.isEmpty { state.clearResults() }
                }
                ForEach(MessageKind.allCases, id: \.self) { kind in
                    Button(kind.label) {
                        state.query = ""
                        state.kind = kind
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(state.kind == nil ? PaiPalette.Semantic.textMuted : PaiPalette.primary500)
            }
            .accessibilityIdentifier("transcript-search-kind-picker")

            HStack(spacing: 4) {
                Button {
                    state.requestPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(state.total == 0)
                .accessibilityIdentifier("transcript-search-previous")

                Button {
                    state.requestNext()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(state.total == 0)
                .accessibilityIdentifier("transcript-search-next")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(PaiPalette.Semantic.textPrimary)

            Button("Done") { state.close() }
                .font(PaiTypography.bodyEmphasized.font)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("transcript-search-bar")
        .onAppear { isFocused = true }
    }
}
