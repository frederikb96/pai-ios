import PAIKit
import SwiftUI
import UIKit

/// The read-only rendering of a note's markdown as a page, not a chat bubble: headings and
/// paragraphs at a size meant to be read rather than typed into, laid out and scrolled freely.
/// `[[wikilinks]]` are resolved against the loaded index and turned into a link (or struck
/// through when dead), and `![[embeds]]` render as attachments — an image inline, anything else a
/// tappable chip offering to save it.
///
/// Deliberately its own renderer rather than a reuse of the transcript's `MarkdownContentView`.
/// That view's spacing and code/table sizing are tuned to agree with `TranscriptRowLayout`'s
/// *precomputed* heights — a constraint that exists only because the transcript measures a row
/// before it is ever laid out, which a freely-scrolled note page never has to do and should not
/// inherit. Typography comes from ``PaiTypography``'s own `markdown*` ramp — already the scale
/// this app derived from the web's rendered-markdown CSS, not from `NoteEditorTheme`'s heading
/// sizes, which that type's own doc comment says are for an editor's typing size and are "far too
/// large" as rendered output. Colour comes from `PaiPalette.Notes.*`, the same tokens the editor
/// itself paints with, so toggling between preview and edit changes nothing about how the note
/// looks — only whether its markup is visible.
struct NoteBodyView: View {
    let noteBody: String
    let nameToId: [String: String]
    let containerId: String?
    let jump: NoteJumpRequest?
    let highlight: String?

    @Environment(AppEnvironment.self) private var environment
    @Environment(NotesStore.self) private var notes
    // Loaded once per container rather than threaded in from a caller: every wikilink resolution
    // in this note needs it, and a link to an existing attachment must resolve the same way the
    // web does — without it, every plain `[[attachments/foo]]` wikilink reads as dead (missing)
    // even though the file exists, because a wikilink target that isn't a note name would
    // otherwise never be checked against anything else.
    @State private var attachmentIndex = AttachmentIndex.empty

    init(
        body: String, nameToId: [String: String], containerId: String?,
        jump: NoteJumpRequest? = nil, highlight: String? = nil
    ) {
        self.noteBody = body
        self.nameToId = nameToId
        self.containerId = containerId
        self.jump = jump
        self.highlight = highlight
    }

    var body: some View {
        let document = NotePreviewDocument(body: noteBody, nameToId: nameToId, attachmentIndex: attachmentIndex)
        let currentItemIndex = jump.flatMap {
            document.itemIndex(forCharacterOffset: $0.characterOffset, in: noteBody)
        }

        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, not `VStack`: a long note can carry dozens of embeds, and a plain `VStack`
                // builds every row up front — each attachment's `.task` fires immediately on
                // appearance (`NoteAttachmentEmbedView`'s own doc comment), so opening a note with
                // many embeds fired that many concurrent fetches and image decodes at once before
                // anything was even on screen. `LazyVStack` still registers every row's `.id(_:)`
                // up front, so `proxy.scrollTo` below is unaffected — only building and appearing
                // off-screen rows is deferred.
                LazyVStack(alignment: .leading, spacing: NotePreviewMetrics.blockSpacing) {
                    ForEach(document.items) { item in
                        itemView(item, isCurrentTarget: item.id == currentItemIndex)
                            .id(item.id)
                    }
                }
                .padding(NotePreviewMetrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `initial: true` covers both a jump arriving while this view is already on screen
            // (tapping a heading while already previewing) and one that was already pending when
            // preview mode was entered (tapping a heading, then switching into preview) — one
            // mechanism for both rather than a duplicate scroll call in `.onAppear`.
            .onChange(of: jump, initial: true) { _, request in
                guard let request,
                    let index = document.itemIndex(forCharacterOffset: request.characterOffset, in: noteBody)
                else { return }
                withAnimation {
                    proxy.scrollTo(document.items[index].id, anchor: UnitPoint(x: 0.5, y: 0.33))
                }
            }
        }
        .background(PaiPalette.Notes.background)
        // Pushed as `.notePreview`, not `.note`: a link tapped from this page is by definition
        // read while previewing, and following it should land on the same rendered page rather
        // than dropping into the target note's editor.
        .confirmingExternalLinks(onNoteLink: { id in environment.router.push(.notePreview(id: id)) })
        // Reloads whenever the container changes (a different note opened in place) or is nil
        // (nothing to resolve against, matching the initial `.empty` state).
        .task(id: containerId) {
            guard let containerId else {
                attachmentIndex = .empty
                return
            }
            attachmentIndex =
                (try? await buildAttachmentIndex(notes.listAttachments(containerId: containerId))) ?? .empty
        }
    }

    @ViewBuilder
    private func itemView(_ item: NotePreviewItem, isCurrentTarget: Bool) -> some View {
        switch item.kind {
        case .block(let block):
            NotePreviewBlockView(block: block, highlightQuery: highlight, isCurrentTarget: isCurrentTarget)
        case .embed(let target, _):
            attachmentView(target: target, mode: .embed)
        case .attachmentLink(let target):
            attachmentView(target: target, mode: .link)
        }
    }

    @ViewBuilder
    private func attachmentView(target: String, mode: NoteAttachmentEmbedView.Mode) -> some View {
        if let containerId {
            NoteAttachmentEmbedView(containerId: containerId, target: target, mode: mode)
        } else {
            Text("\(target) — this note has no container, so its attachments can't be resolved")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Notes.muted)
        }
    }
}

enum NotePreviewMetrics {
    static let blockSpacing: CGFloat = 14
    static let pagePadding: CGFloat = 16
}

/// One top-level block, styled with the same page-reading typography and Notes-theme colours
/// throughout. Recurses for `.blockQuote`/`.list`, mirroring `MarkdownContentView`'s own shape —
/// a nested nesting level narrows by the inset its marker or rule reserves, exactly as there.
///
/// `highlightQuery` paints every occurrence of that text found in this block's own rendered
/// content — searched directly against what is on screen (``findOccurrences(body:query:)`` run
/// against `MarkdownBlock/plainText`), not by re-locating a raw-body character offset inside
/// rendered text, which markdown syntax stripped out of that text would make unreliable. A hit
/// inside a nested list item or block quote still scrolls to the right block but is not painted
/// character-for-character inside it — the same scope cut `MarkdownContentView`'s own doc comment
/// makes for the transcript, for the same reason: nothing here indexes into nested content.
struct NotePreviewBlockView: View {
    let block: MarkdownBlock
    var highlightQuery: String?
    var isCurrentTarget: Bool = false

    var body: some View {
        switch block {
        case .paragraph(let text):
            styledText(text, style: PaiTypography.markdownBody, baseColor: PaiPalette.Notes.text)
                .textSelection(.enabled)

        case .heading(let level, let text):
            styledText(text, style: headingStyle(level), baseColor: PaiPalette.Notes.heading)
                .textSelection(.enabled)

        case .codeBlock(_, let code):
            // Scrolls sideways rather than wrapping — the same rule the transcript and the editor
            // both hold to, so a long line stays readable code instead of reflowing into
            // something that no longer is.
            ScrollView(.horizontal, showsIndicators: true) {
                TranscriptTextHighlighting.plainText(
                    code, font: PaiTypography.markdownCodeBlock.font, highlights: highlightSpans(in: code)
                )
                .foregroundStyle(PaiPalette.Notes.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PaiPalette.Notes.codeBackground, in: RoundedRectangle(cornerRadius: 6))

        case .blockQuote(let nested):
            HStack(spacing: 10) {
                Rectangle().fill(PaiPalette.Notes.rule).frame(width: 3)
                VStack(alignment: .leading, spacing: NotePreviewMetrics.blockSpacing) {
                    ForEach(Array(nested.enumerated()), id: \.offset) { _, block in
                        NotePreviewBlockView(block: block)
                    }
                }
            }

        case .list(let list):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker(for: list.marker, index: index, checkbox: item.checkbox))
                            .font(PaiTypography.markdownBody.font)
                            .foregroundStyle(PaiPalette.Notes.accent)
                        VStack(alignment: .leading, spacing: NotePreviewMetrics.blockSpacing) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                                NotePreviewBlockView(block: block)
                            }
                        }
                    }
                }
            }

        case .table(let table):
            NotePreviewTableView(table: table)

        case .thematicBreak:
            Rectangle().fill(PaiPalette.Notes.rule).frame(height: 1)

        case .htmlBlock(let raw):
            TranscriptTextHighlighting.plainText(
                raw, font: PaiTypography.markdownCodeBlock.font, highlights: highlightSpans(in: raw)
            )
            .foregroundStyle(PaiPalette.Notes.muted)
        }
    }

    private func marker(for marker: MarkdownList.Marker, index: Int, checkbox: MarkdownListItem.Checkbox?) -> String {
        if let checkbox {
            return checkbox == .checked ? "☑" : "☐"
        }
        switch marker {
        case .bullet: return "•"
        case .ordered(let start): return "\(Int(start) + index)."
        }
    }

    private func headingStyle(_ level: Int) -> PaiTypography.Style {
        switch level {
        case 1: return PaiTypography.markdownHeading1
        case 2: return PaiTypography.markdownHeading2
        case 3: return PaiTypography.markdownHeading3
        default: return PaiTypography.markdownHeading4
        }
    }

    /// Every occurrence of `highlightQuery` in `text`, in this block's own rendered coordinates —
    /// `highlightRanges` hands back Character ranges already relative to `text` itself, safe to
    /// convert straight to an `NSRange` because `Foundation` does the UTF-16 conversion, not
    /// hand-rolled Character/byte arithmetic. The first occurrence is marked current exactly when
    /// this block is the one the jump landed on — a cheap way to distinguish it from the rest,
    /// correct whenever a block has only one hit, which is most of them.
    private func highlightSpans(in text: String) -> [TranscriptHighlightSpan] {
        guard let highlightQuery, !highlightQuery.isEmpty else { return [] }
        return highlightRanges(in: text, query: highlightQuery).enumerated().map { index, range in
            (range: NSRange(range, in: text), isCurrent: isCurrentTarget && index == 0)
        }
    }

    /// Builds one block's text as a single `AttributedString` — a search highlight needs a
    /// background colour on an arbitrary sub-range, which only `Text(AttributedString)` can carry
    /// without inserting anything into the text. Mirrors `MarkdownContentView.styledText` with the
    /// page's own typography and the Notes palette in place of the transcript's.
    private func styledText(_ inline: InlineText, style: PaiTypography.Style, baseColor: Color) -> Text {
        let source = inline.plainText
        var attributed = AttributedString(source)
        attributed.font = style.font
        attributed.foregroundColor = baseColor

        var cursor = 0
        for run in inline.runs {
            let length = run.text.utf16.count
            defer { cursor += length }
            guard length > 0,
                let range = TranscriptTextHighlighting.attributedRange(
                    NSRange(location: cursor, length: length), source: source, in: attributed)
            else { continue }

            if run.style.contains(.code) {
                attributed[range].font = PaiTypography.markdownInlineCode.font
                attributed[range].backgroundColor = PaiPalette.Notes.codeBackground
            }
            var intent: InlinePresentationIntent = []
            if run.style.contains(.bold) {
                intent.insert(.stronglyEmphasized)
                attributed[range].foregroundColor = PaiPalette.Notes.heading
            }
            if run.style.contains(.italic) { intent.insert(.emphasized) }
            if !intent.isEmpty { attributed[range].inlinePresentationIntent = intent }
            if run.style.contains(.strikethrough) { attributed[range].strikethroughStyle = .single }
            if let destination = run.destination {
                attributed[range].foregroundColor = PaiPalette.Notes.accent
                attributed[range].underlineStyle = .single
                // A destination that fails to parse is left as plain styled text — a broken link
                // that does nothing beats one that opens something arbitrary.
                if let url = URL(string: destination) {
                    attributed[range].link = url
                }
            }
        }

        TranscriptTextHighlighting.apply(highlightSpans(in: source), to: &attributed, source: source)
        return Text(attributed)
    }
}

/// A GFM table, its own horizontally-scrolling grid — a cell never wraps, matching the transcript
/// and the web's own `overflow-x-auto` on every table.
struct NotePreviewTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                        Text(cell.plainText)
                            .font(PaiTypography.bodyEmphasized.font)
                            .foregroundStyle(PaiPalette.Notes.heading)
                    }
                }
                // Outside any `GridRow`, this spans every column automatically — the documented
                // `Grid` behaviour `GfmTableView`'s own `Divider()` already relies on.
                Rectangle().fill(PaiPalette.Notes.rule).frame(height: 1)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell.plainText)
                                .font(PaiTypography.markdownBody.font)
                                .foregroundStyle(PaiPalette.Notes.text)
                        }
                    }
                }
            }
        }
    }
}

/// An Obsidian embed (`![[attachments/foo.png]]`) or a plain wikilink resolved to an attachment
/// (`[[attachments/foo.png]]`), rendered inline: in ``Mode/embed`` mode an image renders in place
/// and opens the shared ``FullScreenImageViewer`` on tap — the same interaction and the same
/// viewer a session's own attachments use — and anything else is a tappable chip that confirms
/// before handing the file to the system share sheet, so a stray tap can never start a download on
/// its own. In ``Mode/link`` mode every attachment, image included, always renders as the download
/// chip: a plain wikilink is a *reference* to open the file, not a request to embed it inline —
/// only `![[...]]` means that, mirroring the web's `NoteAttachmentEmbed` `mode` prop. Loads on
/// appearance rather than deferring to a tap on the chip itself — a note body carries only its own
/// handful of attachments, unlike a long chat transcript.
struct NoteAttachmentEmbedView: View {
    enum Mode: Equatable {
        case embed
        case link
    }

    let containerId: String
    let target: String
    var mode: Mode = .embed

    @Environment(NotesStore.self) private var notes
    @State private var state: LoadState = .loading
    @State private var isConfirmingDownload = false
    @State private var shareFile: AttachmentShareFile?
    @State private var fullScreenTarget: FullScreenImageTarget?

    private enum LoadState {
        case loading
        case loaded(Data)
        case notFound
        case error
    }

    var body: some View {
        Group {
            switch state {
            case .loaded(let data):
                if mode == .embed, isImage, let uiImage = UIImage(data: data) {
                    Button {
                        fullScreenTarget = FullScreenImageTarget(image: uiImage, filename: filename)
                    } label: {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View \(filename)")
                } else {
                    Button {
                        isConfirmingDownload = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc")
                            Text(filename)
                        }
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Notes.accent)
                        .padding(8)
                        .background(PaiPalette.Notes.codeBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(
                        "Download \(filename)?", isPresented: $isConfirmingDownload, titleVisibility: .visible
                    ) {
                        Button("Download") { prepareShare(data) }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                    Text(filename)
                }
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Notes.muted)
            case .notFound:
                Label(
                    "\(filename) — not available here, likely on the laptop only",
                    systemImage: "photo.badge.exclamationmark"
                )
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Notes.muted)
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
        .sheet(item: $shareFile) { file in
            AttachmentShareSheet(activityItems: [file.url])
        }
        .fullScreenImageViewer($fullScreenTarget)
    }

    private func prepareShare(_ data: Data) {
        shareFile = AttachmentSharing.stage(data, filename: filename)
    }

    private var filename: String {
        attachmentFilename(target)
    }

    private var isImage: Bool {
        isImageAttachmentPath(target)
    }
}
