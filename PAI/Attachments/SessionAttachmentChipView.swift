import PAIKit
import SwiftUI

/// One attachment reference inside a transcript row — a file the user attached when composing, or
/// a `pai-file:` marker an agent wrote to show the user one of its own. Loads on tap, never on
/// appearance: a session transcript can carry far more of these than a note ever does (see
/// ``NoteAttachmentEmbedView``'s own doc comment on that asymmetry), so scrolling past one must
/// cost nothing.
///
/// A fixed height (``TranscriptRowMetrics/attachmentChipHeight``) in every state, on purpose —
/// the transcript's row height is precomputed before this cell is ever laid out (see
/// `docs/ARCHITECTURE.md` "Reading the transcript"), so nothing here
/// may grow to show a loaded image inline. An image or PDF goes straight to
/// ``FilePreviewViewer`` instead once it loads, which is the right call on iOS when
/// inline expansion would cost a row a height nobody measured.
struct SessionAttachmentChipView: View {
    let sessionID: String
    let apiClient: PaiApiClient
    let path: String
    /// True for a `pai-file:` marker the agent offered from its own machine — a file with no
    /// preview is not fetched by the tap: the viewer's card holds it back until Download is
    /// pressed, since it ends up saved on the device. An image or PDF is fetched only to be shown. False for a file the user attached
    /// when composing, which they already know about and chose to send.
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
    @State private var previewTarget: FilePreviewTarget?

    private var kind: AttachmentPreviewKind { AttachmentPreviewKind(path: path) }
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
        .accessibilityLabel(kind.isPreviewable ? "View \(filename)" : filename)
        .filePreview($previewTarget)
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle:
            Image(systemName: idleSymbol)
        case .loading:
            ProgressView().controlSize(.mini)
        case .loaded:
            Image(systemName: loadedSymbol)
        case .notFound:
            Image(systemName: "questionmark.folder")
        case .error:
            Image(systemName: "exclamationmark.triangle")
        }
    }

    private var idleSymbol: String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .other: return "doc"
        }
    }

    private var loadedSymbol: String {
        switch kind {
        case .image: return "photo.fill"
        case .pdf: return "doc.richtext.fill"
        case .other: return "checkmark.circle.fill"
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
            if !kind.isPreviewable && requiresConfirmation {
                previewTarget = FilePreviewTarget(filename: filename, load: { await fetch() })
            } else {
                load()
            }
        }
    }

    private func fetch() async -> FilePreviewTarget.Fetch {
        do {
            switch try await apiClient.getAttachment(sessionId: sessionID, path: path) {
            case .ok(let data, _): return .ok(data)
            case .notFound: return .notFound
            case .error(let paiError): return .failed(paiError.userMessage)
            }
        } catch let paiError as PaiError {
            return .failed(paiError.userMessage)
        } catch {
            return .failed("Could not load attachment")
        }
    }

    private func load() {
        state = .loading
        Task {
            switch await fetch() {
            case .ok(let data):
                state = .loaded(data)
                present(data)
            case .notFound:
                state = .notFound
            case .failed(let message):
                errorDetail = message
                state = .error
            }
        }
    }

    /// What "open" means once bytes are in hand — always the full-screen viewer, which draws an
    /// image or PDF and offers everything else as a card with the share sheet behind its button.
    /// Called both right after a fresh load and on a repeat tap of an already-loaded chip, so a
    /// second tap never re-fetches.
    private func present(_ data: Data) {
        previewTarget = FilePreviewTarget(data: data, filename: filename)
    }
}
