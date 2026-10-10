import PAIKit
import SwiftUI

/// The attachments of one sent message: the first few as chips, the rest behind a "+N more" row
/// that opens the whole list in a sheet.
///
/// A message may carry any number of files. The transcript's row heights are precomputed, so this
/// draws exactly ``AttachmentListBound/transcriptRowCount(total:)`` rows of
/// ``TranscriptRowMetrics/attachmentChipHeight`` each — `TranscriptRowLayout` sums the same
/// number, and a figure that moves here and not there is a row drawn taller than its cell. The
/// full list lives in a sheet for that reason: opening it never changes the row.
struct SessionAttachmentListView: View {
    let paths: [String]
    let sessionID: String
    let apiClient: PaiApiClient

    @State private var showingAll = false

    private var hiddenCount: Int {
        AttachmentListBound.hiddenCount(total: paths.count, limit: AttachmentListBound.transcriptVisible)
    }

    var body: some View {
        ForEach(paths.prefix(AttachmentListBound.transcriptVisible), id: \.self) { path in
            // Freddy's own file, already known to him — no confirmation before it is fetched,
            // unlike a `pai-file:` marker (see `AssistantProseView`).
            SessionAttachmentChipView(
                sessionID: sessionID, apiClient: apiClient, path: path, requiresConfirmation: false)
        }
        if hiddenCount > 0 {
            Button {
                showingAll = true
            } label: {
                Text("+\(hiddenCount) more")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            .buttonStyle(.plain)
            .frame(height: TranscriptRowMetrics.attachmentChipHeight, alignment: .leading)
            .accessibilityIdentifier("attachment-list-more")
            .sheet(isPresented: $showingAll) {
                NavigationStack {
                    List(paths, id: \.self) { path in
                        SessionAttachmentChipView(
                            sessionID: sessionID, apiClient: apiClient, path: path, requiresConfirmation: false)
                    }
                    .listStyle(.plain)
                    .navigationTitle("Attachments (\(paths.count))")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingAll = false }
                        }
                    }
                }
            }
        }
    }
}
