import PAIKit
import SwiftUI

/// One attachment reference inside a transcript row — a file Freddy attached when composing, or
/// a `pai-file:` marker an agent wrote to show him one of its own. Loads on tap, never on
/// appearance: a session transcript can carry far more of these than a note ever does (see
/// ``NoteAttachmentEmbedView``'s own doc comment on that asymmetry), so scrolling past one must
/// cost nothing.
///
/// A fixed height (``TranscriptRowMetrics/attachmentChipHeight``) in every state, on purpose —
/// the transcript's row height is precomputed before this cell is ever laid out (see
/// `docs/ARCHITECTURE.md` "Reading the transcript" and the `scrolling` skill), so nothing here
/// may grow to show a loaded image inline. An image goes straight to
/// ``FullScreenImageViewer`` instead once it loads, which Freddy asked for explicitly as the
/// right call on iOS when inline expansion would cost a row a height nobody measured.
struct SessionAttachmentChipView: View {
    let sessionID: String
    let apiClient: PaiApiClient
    let path: String
    /// True for a `pai-file:` marker the agent offered from its own machine — a non-image needs
    /// an explicit confirmation before anything is fetched. False for a file Freddy attached
    /// himself when composing, which he already knows about and chose to send.
    let requiresConfirmation: Bool

    private enum LoadState {
        case idle
        case loading
        case loaded(Data)
        case notFound
        case error
    }

    @State private var state: LoadState = .idle
    @State private var errorDetail: String?
    @State private var confirmingDownload = false
    @State private var fullScreenTarget: FullScreenImageTarget?
    @State private var shareFile: AttachmentShareFile?

    private var isImage: Bool { isImageAttachmentPath(path) }
    private var filename: String { attachmentFilename(path) }

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 4) {
                icon
                Text(labelText)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .font(PaiTypography.caption.font)
        .foregroundStyle(PaiPalette.Semantic.textMuted)
        .frame(height: TranscriptRowMetrics.attachmentChipHeight, alignment: .leading)
        .disabled(isLoading)
        .accessibilityLabel(isImage ? "View \(filename)" : filename)
        .fullScreenImageViewer($fullScreenTarget)
        .sheet(item: $shareFile) { file in AttachmentShareSheet(activityItems: [file.url]) }
        .confirmationDialog(
            "Download \(filename)?", isPresented: $confirmingDownload, titleVisibility: .visible
        ) {
            Button("Download") { load() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "An agent offered “\(filename)” from its own machine. It will be fetched through the connection "
                    + "and saved to your device.")
        }
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle:
            Image(systemName: isImage ? "photo" : "doc")
        case .loading:
            ProgressView().controlSize(.mini)
        case .loaded:
            Image(systemName: isImage ? "photo.fill" : "checkmark.circle.fill")
        case .notFound:
            Image(systemName: "questionmark.folder")
        case .error:
            Image(systemName: "exclamationmark.triangle")
        }
    }

    private var labelText: String {
        switch state {
        case .notFound: return "No longer available"
        case .error: return errorDetail ?? "Could not load attachment"
        default: return filename
        }
    }

    /// `.idle`/`.notFound`/`.error` all retry on tap — the same allowance web's `load()` gives a
    /// transient failure, guarded only against re-firing while a fetch is already in flight or
    /// re-fetching what is already sitting in `state`.
    private func handleTap() {
        switch state {
        case .loading:
            return
        case .loaded(let data):
            present(data)
        case .idle, .notFound, .error:
            if !isImage && requiresConfirmation {
                confirmingDownload = true
            } else {
                load()
            }
        }
    }

    private func load() {
        state = .loading
        Task {
            do {
                switch try await apiClient.getAttachment(sessionId: sessionID, path: path) {
                case .ok(let data, _):
                    state = .loaded(data)
                    present(data)
                case .notFound:
                    state = .notFound
                case .error(let paiError):
                    errorDetail = paiError.userMessage
                    state = .error
                }
            } catch let paiError as PaiError {
                errorDetail = paiError.userMessage
                state = .error
            } catch {
                errorDetail = "Could not load attachment"
                state = .error
            }
        }
    }

    /// What "open" means once bytes are in hand — the full-screen viewer for a real image, the
    /// share sheet for everything else. Called both right after a fresh load and on a repeat tap
    /// of an already-loaded chip, so a second tap never re-fetches.
    ///
    /// A path that looked like an image by extension but fails to decode falls through to the
    /// share sheet instead of doing nothing — the same graceful degradation
    /// ``NoteAttachmentEmbedView`` already gives this exact case.
    private func present(_ data: Data) {
        if isImage, let image = UIImage(data: data) {
            fullScreenTarget = FullScreenImageTarget(image: image, filename: filename)
        } else {
            shareFile = AttachmentSharing.stage(data, filename: filename)
        }
    }
}
