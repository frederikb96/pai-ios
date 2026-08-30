import PAIKit
import SwiftUI
import UIKit

/// The read-only rendering of a note's markdown: `[[wikilinks]]` resolved against the loaded
/// index and turned into a link (or struck through when dead), `![[embeds]]` rendered as
/// attachments, everything else exactly what `MarkdownContentView` already renders for a chat
/// bubble — the same reuse the web's `NoteBody.tsx` makes of its own bubble renderer, rather than
/// forking a second markdown renderer for notes.
///
/// A resolved wikilink becomes the app's own `pai://note/<id>` link, and the tap is caught here
/// rather than handed to the system: navigating in place keeps the reader's back stack, where
/// letting it out and back in through `onOpenURL` would replace the whole path. Anything else —
/// a real `https://` link in the note — falls through to the system unchanged.
struct NoteBodyView: View {
    let noteBody: String
    let nameToId: [String: String]
    let containerId: String?

    @Environment(AppEnvironment.self) private var environment

    init(body: String, nameToId: [String: String], containerId: String?) {
        self.noteBody = body
        self.nameToId = nameToId
        self.containerId = containerId
    }

    var body: some View {
        let segments = splitBodyForRender(noteBody, nameToId: nameToId)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let markdown):
                        MarkdownContentView(blocks: MarkdownParser.parse(markdown))
                    case .embed(let target, _):
                        if let containerId {
                            NoteAttachmentEmbedView(containerId: containerId, target: target)
                        } else {
                            Text("\(target) — this note has no container, so its attachments can't be resolved")
                                .font(PaiTypography.caption.font)
                                .foregroundStyle(PaiPalette.Semantic.textMuted)
                        }
                    }
                }
            }
            .padding()
        }
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard case .note(let id) = DeepLink.from(url: url) else { return .systemAction }
                environment.router.push(.note(id: id))
                return .handled
            })
    }
}

/// An Obsidian embed (`![[attachments/foo.png]]`) rendered inline: an image renders in place,
/// anything else offers a download. Loads on appearance rather than deferring to a tap — a note
/// body carries only its own handful of attachments, unlike a long chat transcript.
private struct NoteAttachmentEmbedView: View {
    let containerId: String
    let target: String

    @Environment(NotesStore.self) private var notes
    @State private var state: State = .loading

    private enum State {
        case loading
        case loaded(Data)
        case notFound
        case error
    }

    var body: some View {
        Group {
            switch state {
            case .loaded(let data):
                if isImage, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                        Text(filename)
                    }
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.primary700)
                    .padding(8)
                    .background(PaiPalette.primary50, in: RoundedRectangle(cornerRadius: 8))
                }
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                    Text(filename)
                }
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            case .notFound:
                Label(
                    "\(filename) — not available here, likely on the laptop only",
                    systemImage: "photo.badge.exclamationmark"
                )
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            case .error:
                Label("Could not load \(filename)", systemImage: "exclamationmark.triangle")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
        .task(id: target) {
            state = .loading
            do {
                switch try await notes.fetchAttachment(containerId: containerId, path: target) {
                case .ok(let data): state = .loaded(data)
                case .notFound: state = .notFound
                }
            } catch {
                state = .error
            }
        }
    }

    private var filename: String {
        target.split(separator: "/").last.map(String.init) ?? target
    }

    private var isImage: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext)
    }
}
