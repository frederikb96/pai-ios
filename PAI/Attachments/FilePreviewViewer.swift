import PAIKit
import PDFKit
import SwiftUI

/// One file, shown full-screen without saving it — the single viewer every preview in the app
/// opens, whether the file came from a session attachment, a `pai-file:` marker, a note's embed or
/// the canteen's menus. An image zooms, a PDF scrolls and zooms, and a file that cannot be drawn
/// gets a card whose button is the deliberate step that saves it: the share sheet, preceded by the
/// fetch when the file was not downloaded yet.
///
/// Unlike the web's version, this carries a share button rather than relying on a long-press:
/// The web's "the browser's own right-click already gives copy and save" has no equivalent
/// gesture affordance on a touchscreen. Saving is that button, never a side effect of opening.
struct FilePreviewViewer: View {
    /// What is on screen: the presented target, then each picture a step moved to. Replaced here
    /// rather than through the presenter's binding, since a new value there opens a fresh cover.
    @State private var shown: FilePreviewTarget

    init(target: FilePreviewTarget) {
        _shown = State(initialValue: target)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var shareFile: AttachmentShareFile?
    @State private var zoomScale: CGFloat = 1
    @State private var pdfIsAtRest = true
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var isStepping = false

    /// How close to the resting scale still counts as "not zoomed" for the swipe-to-dismiss gate
    /// below — `UIScrollView` settles fractionally off `1.0` after its own rubber-band animation,
    /// so an exact-equality check would leave the gesture permanently disabled after the first
    /// pinch.
    private static let restScaleTolerance: CGFloat = 1.01

    /// Space the header takes at the top of content that is not full-bleed, so a PDF's first
    /// lines and the unavailable card start below it.
    private static let headerClearance: CGFloat = 64

    /// The swipe-to-dismiss gate: an image at rest scale, a PDF at its fitted width and scrolled
    /// to the top. Otherwise a downward drag belongs to the content, which pans or scrolls.
    private var allowsSwipeDismiss: Bool {
        zoomScale <= Self.restScaleTolerance && pdfIsAtRest
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .overlay(alignment: .top) { header }
        .sheet(item: $shareFile) { file in
            AttachmentShareSheet(activityItems: [file.url])
        }
        // A swipe down is the platform's own dismiss gesture for a full-screen presentation —
        // tapping the content itself does nothing, matching the web's "outside the image, never on
        // it" rule, translated to the one gesture iOS already gives a modal for free. Gated on
        // resting state, matching Photos: once zoomed in, a downward drag pans inside the content
        // instead of dismissing the screen.
        //
        // A sideways swipe at rest steps to the neighbouring picture when the target offers one;
        // whichever axis the drag mostly follows decides between stepping and dismissing.
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard allowsSwipeDismiss else { return }
                    let width = value.translation.width
                    let height = value.translation.height
                    if abs(width) > abs(height) {
                        if abs(width) > 80 { stepPicture(width > 0 ? .previous : .next) }
                    } else if height > 80 {
                        dismiss()
                    }
                }
        )
    }

    /// Swiping right shows the previous (older) picture, as in Photos. One step at a time: a swipe
    /// while the neighbour is still loading is ignored.
    private func stepPicture(_ direction: PictureStepDirection) {
        guard let step = shown.step, !isStepping else { return }
        isStepping = true
        Task {
            defer { isStepping = false }
            guard let next = await step(direction) else { return }
            withAnimation(.easeInOut(duration: 0.2)) { shown = next }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch shown.content {
        case .image(let image):
            ZoomableImageView(image: image, zoomScale: $zoomScale)
                .ignoresSafeArea()
                .id(shown.id)
                .transition(.opacity)
        case .pdf(let document):
            PDFPreviewView(document: document, isAtRest: $pdfIsAtRest)
                .ignoresSafeArea(edges: .bottom)
                .padding(.top, Self.headerClearance)
        case .unavailable:
            unavailableCard
                .padding(.top, Self.headerClearance)
        }
    }

    /// Shown for a file the viewer cannot draw: a type it has no preview for, or bytes that do not
    /// decode as the image or PDF their name claims. A file that was not fetched yet is fetched
    /// only when its button is pressed.
    private var unavailableCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 44))
            Text(shown.filename)
                .font(PaiTypography.bodyEmphasized.font)
                .multilineTextAlignment(.center)
            Text("No preview available")
                .font(PaiTypography.body.font)
                .foregroundStyle(.white.opacity(0.7))
            if let fetchError {
                Text(fetchError)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await saveFromCard() }
            } label: {
                if isFetching {
                    ProgressView()
                } else {
                    Text(shown.data == nil ? "Download" : "Share or save")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isFetching)
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(shown.filename)
                .font(PaiTypography.captionEmphasized.font)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // A plain icon or title straight over the content is illegible against a light or
                // busy region of it — the same class of "foreground content with nothing behind it
                // to guarantee contrast" as the sign-in card's own bug, just with the roles of
                // foreground and background swapped. A material scrim guarantees legibility
                // regardless of what is under it, the way Photos' own toolbar does, without
                // needing a fixed opaque colour that would look wrong in light mode.
                .background(.thinMaterial, in: Capsule())
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                if shown.data != nil {
                    Button {
                        share()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                    }
                    .accessibilityLabel("Share \(shown.filename)")
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                }
                .accessibilityLabel("Close")
            }
            .padding(10)
            .background(.thinMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
        .padding()
    }

    private func share() {
        guard let data = shown.data else { return }
        shareFile = AttachmentSharing.stage(data, filename: shown.filename)
    }

    /// Fetches first when the target carries only a loader, then opens the share sheet.
    private func saveFromCard() async {
        if shown.data != nil {
            share()
            return
        }
        guard let load = shown.load else { return }
        isFetching = true
        fetchError = nil
        defer { isFetching = false }
        switch await load() {
        case .ok(let data):
            shareFile = AttachmentSharing.stage(data, filename: shown.filename)
        case .notFound:
            fetchError = "No longer available"
        case .failed(let message):
            fetchError = message
        }
    }
}

/// What ``FilePreviewViewer`` needs to be presented as a `.fullScreenCover(item:)` — one value per
/// presentation, so tapping a second file while the first is still loading (unlikely, but the type
/// should not assume it cannot happen) opens a fresh cover rather than mutating one already on
/// screen.
struct FilePreviewTarget: Identifiable {
    enum Content {
        case image(UIImage)
        case pdf(PDFDocument)
        /// A type with no preview, or bytes that do not decode as the kind the name claims.
        case unavailable
    }

    /// What a ``load`` produced.
    enum Fetch {
        case ok(Data)
        case notFound
        case failed(String)
    }

    let id = UUID()
    /// The file as fetched, what the share button hands on; `nil` while only ``load`` can get it.
    let data: Data?
    let filename: String
    let content: Content
    /// Fetches a file nobody asked to download yet (an agent-offered `pai-file:` with no
    /// preview). The viewer calls it only when the card's Download button is pressed, so a stray
    /// tap on the chip never saves anything.
    let load: (@MainActor () async -> Fetch)?

    /// Produces the picture next to this one, or `nil` when there is none to show. Set only by the
    /// transcript's pictures; every other caller leaves it `nil` and gets a viewer that does not step.
    typealias Step = @MainActor (PictureStepDirection) async -> FilePreviewTarget?
    let step: Step?

    /// - Parameter kind: the file's kind when the filename does not say (a canteen PDF whose mail
    ///   name has no extension); defaults to what the filename's extension says.
    init(data: Data, filename: String, kind: AttachmentPreviewKind? = nil, step: Step? = nil) {
        self.data = data
        self.filename = filename
        self.step = step
        load = nil
        switch kind ?? AttachmentPreviewKind(path: filename) {
        case .image:
            content = UIImage(data: data).map(Content.image) ?? .unavailable
        case .pdf:
            content = PDFDocument(data: data).map(Content.pdf) ?? .unavailable
        case .other:
            content = .unavailable
        }
    }
}

extension FilePreviewTarget {
    /// A file with no preview whose bytes are fetched by the card's Download button.
    init(filename: String, load: @escaping @MainActor () async -> Fetch) {
        data = nil
        self.filename = filename
        self.load = load
        step = nil
        content = .unavailable
    }
}

extension View {
    /// See ``FilePreviewViewer``.
    func filePreview(_ target: Binding<FilePreviewTarget?>) -> some View {
        fullScreenCover(item: target) { value in
            FilePreviewViewer(target: value)
        }
    }
}
