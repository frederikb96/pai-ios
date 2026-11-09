import PAIKit
import SwiftUI
import UIKit

/// An image a reply's `pai-file:` line names, drawn as a thumbnail where the line stood instead of
/// a chip; a tap opens it in ``FilePreviewViewer``, which holds download and copy. Fetched through
/// the same attachment route as the chip.
///
/// Always exactly ``TranscriptRowMetrics/inlineImageHeight`` tall, in every state: the row's height
/// is precomputed before the image is fetched, so the picture is fitted into a box whose size
/// never depends on it. A wide image leaves room below it, a tall one beside it.
///
/// Loads when it appears, unlike the chip: an image is shown, not offered. A fetched image is kept
/// in ``SessionInlineImageCache`` so a cell scrolled out and back draws it in its first frame.
struct SessionInlineImageView: View {
    let sessionID: String
    let apiClient: PaiApiClient
    let path: String

    private enum LoadState {
        case loading
        case loaded(SessionInlineImageCache.Entry)
        case notFound
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var previewTarget: FilePreviewTarget?

    private var filename: String { attachmentFilename(path) }
    private var key: String { SessionInlineImageCache.key(sessionID: sessionID, path: path) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: TranscriptRowMetrics.inlineImageHeight, alignment: .topLeading)
            .clipped()
            .task(id: key) { await load() }
            .filePreview($previewTarget)
    }

    @ViewBuilder
    private var content: some View {
        switch shown {
        case .loaded(let entry):
            Button {
                previewTarget = FilePreviewTarget(data: entry.data, filename: filename)
            } label: {
                Image(uiImage: entry.image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PaiPalette.Semantic.borderDefault))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(filename)")
        case .loading:
            placeholder(Label(filename, systemImage: "photo"))
        case .notFound:
            placeholder(Label("\(filename) — no longer available", systemImage: "questionmark.folder"))
        case .failed(let message):
            Button {
                Task { await load() }
            } label: {
                placeholder(Label(message, systemImage: "exclamationmark.triangle"))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Tries again")
        }
    }

    private func placeholder(_ label: some View) -> some View {
        label
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }

    /// What to draw this frame: the cache answers during the first body, before the `.task` has
    /// run, so a reused cell never flashes its placeholder over an image already fetched.
    private var shown: LoadState {
        if case .loaded = state { return state }
        if let entry = SessionInlineImageCache.shared.entry(for: key) { return .loaded(entry) }
        return state
    }

    private func load() async {
        if let entry = SessionInlineImageCache.shared.entry(for: key) {
            state = .loaded(entry)
            return
        }
        state = .loading
        let result: PaiAttachmentResult
        do {
            result = try await apiClient.getAttachment(sessionId: sessionID, path: path)
        } catch let paiError as PaiError {
            state = .failed(paiError.userMessage)
            return
        } catch {
            state = .failed("Could not load \(filename)")
            return
        }
        switch result {
        case .ok(let data, _):
            guard let entry = await SessionInlineImageCache.Entry.decode(data) else {
                state = .failed("Could not show \(filename)")
                return
            }
            SessionInlineImageCache.shared.insert(entry, for: key)
            state = .loaded(entry)
        case .notFound:
            state = .notFound
        case .error(let paiError):
            state = .failed(paiError.userMessage)
        }
    }
}

/// The inline images a session's replies have fetched, decoded and scaled down to what the box can
/// show. `NSCache` gives memory back under pressure by itself; the bytes ride along for the viewer
/// and the share sheet, which want the original file.
@MainActor
final class SessionInlineImageCache {
    static let shared = SessionInlineImageCache()

    /// Unchecked because `UIImage` is immutable and documented safe to use from any thread, which
    /// is what lets the decode below hand one back to the main actor.
    final class Entry: @unchecked Sendable {
        let data: Data
        let image: UIImage

        init(data: Data, image: UIImage) {
            self.data = data
            self.image = image
        }

        /// Decodes off the main thread to at most what the box draws at the screen's scale, so a
        /// large screenshot costs its thumbnail's memory rather than its own.
        static func decode(_ data: Data) async -> Entry? {
            guard let full = UIImage(data: data) else { return nil }
            let bound = TranscriptRowMetrics.inlineImageHeight * 3
            let scale = AspectFit.scale(
                fitting: (Double(full.size.width), Double(full.size.height)), into: (bound * 2, bound))
            guard scale < 1 else { return Entry(data: data, image: full) }
            let size = CGSize(width: full.size.width * scale, height: full.size.height * scale)
            let thumbnail = await full.byPreparingThumbnail(ofSize: size)
            return Entry(data: data, image: thumbnail ?? full)
        }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        return cache
    }()

    static func key(sessionID: String, path: String) -> String { "\(sessionID)\n\(path)" }

    func entry(for key: String) -> Entry? { cache.object(forKey: key as NSString) }

    func insert(_ entry: Entry, for key: String) { cache.setObject(entry, forKey: key as NSString) }
}
