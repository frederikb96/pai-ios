import PAIKit
import SwiftUI

/// The transcript's find bar. Replaces the composer while a search is open, rather than
/// overlaying it — the same screen real estate, and the keyboard the reader is about to type into
/// is already anchored to the bottom, which is where Safari's own "Find on Page" puts its bar for
/// the same reason: a thumb reaches the bottom of the screen, not the navigation bar, and the
/// software keyboard is about to claim that space anyway.
///
/// Mutates ``TranscriptSearchState`` directly rather than through closures — every action here
/// (typing, stepping, closing) is a pure state change that type already owns, and
/// `TranscriptCollectionViewController` observes the same shared instance to react: recomputing
/// hits when the query changes, scrolling and painting when the current hit changes. Nothing here
/// needs to know the collection view exists.
struct TranscriptSearchBar: View {
    @Bindable var state: TranscriptSearchState

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                TextField("Find in transcript", text: $state.query)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .onSubmit { state.next() }
                if state.isLoadingFullHistory {
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

            HStack(spacing: 4) {
                Button {
                    state.previous()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(state.hits.isEmpty)
                .accessibilityIdentifier("transcript-search-previous")

                Button {
                    state.next()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(state.hits.isEmpty)
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
